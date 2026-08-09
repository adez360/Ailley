"""DPO 第一輪訓練：驗證有沒有效，不求最佳解。2026-08-09。

資料：transcripts/dpo_chosen_money_fail_v2.json，1875 筆，
欄位 prompt / chosen_output / rejected_output 已經是現成的 triplet。

只跑這一批（money_fail 情境），QLoRA，8GB VRAM 卡上跑，訓練前
已經手動停掉 llama-server 空出 VRAM。
"""
import json
import sys

from datasets import Dataset
from peft import LoraConfig
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
from trl import DPOConfig, DPOTrainer
import torch

MODEL_PATH = "Qwen/Qwen2.5-7B-Instruct"
DATA_PATH = "transcripts/dpo_chosen_money_fail_v2.json"
OUTPUT_DIR = "dpo_output_money_fail_v1"

with open(DATA_PATH, encoding="utf-8") as f:
    raw = json.load(f)

def to_text(output_obj):
    # chosen_output/rejected_output 存的是已經解析好的 dict，訓練要吃字串
    return json.dumps(output_obj, ensure_ascii=False)

rows = [
    {
        "prompt": r["prompt"],
        "chosen": to_text(r["chosen_output"]),
        "rejected": to_text(r["rejected_output"]),
    }
    for r in raw
]
SMOKE_TEST = "--smoke-test" in sys.argv

# 8GB卡上跑，第一輪smoke test量到單一範例前後花約120秒/筆，全量1875筆會
# 跑超過60小時，今天出不了結論。改成分角色分類別抽樣，保留人格分流的代表性，
# 把總筆數壓到跑得完的量級——這是「有沒有效」的是非題，不需要吃全量資料。
import random
random.seed(20260809)
SUBSAMPLE_SIZE = 60  # 2026-08-09：120筆實測要5.7小時，環境問題已經吃掉太多時間，降到60筆求今天出結論
if not SMOKE_TEST and len(raw) > SUBSAMPLE_SIZE:
    by_key = {}
    for i, r in enumerate(raw):
        by_key.setdefault((r["name"], r["category"]), []).append(i)
    keys = list(by_key.keys())
    per_key = max(1, SUBSAMPLE_SIZE // len(keys))
    picked_idx = []
    for k in keys:
        idxs = by_key[k]
        random.shuffle(idxs)
        picked_idx.extend(idxs[:per_key])
    random.shuffle(picked_idx)
    picked_idx = picked_idx[:SUBSAMPLE_SIZE]
    rows = [rows[i] for i in picked_idx]
    print(f"分層抽樣後筆數：{len(rows)}（原始{len(raw)}筆，依name×category分層）")

if SMOKE_TEST:
    rows = rows[:20]

dataset = Dataset.from_list(rows)
print(f"資料筆數：{len(dataset)}（smoke_test={SMOKE_TEST}）")

# 2026-08-09：DPOConfig（繼承transformers TrainingArguments）第一次被存取device相關屬性時
# 會觸發accelerate自己的Accelerator/PartialState初始化。原本寫在model載入「之後」，懷疑
# 這個延遲初始化跟device_map="auto"已經分派好的CUDA context互相干擾，導致後面
# prepare_model_for_kbit_training做in-place dtype轉換時撞"device not ready"（重啟WSL2、
# 換device_map、換bitsandbytes版本都排除不了，只剩這個順序沒試過）。改成先建
# training_args，讓accelerate的裝置初始化先發生，模型載入放在後面。
training_args = DPOConfig(
    output_dir=OUTPUT_DIR,
    per_device_train_batch_size=1,
    gradient_accumulation_steps=4,
    num_train_epochs=1,
    max_steps=3 if SMOKE_TEST else -1,
    learning_rate=5e-5,
    beta=0.1,
    logging_steps=1,
    save_strategy="no" if SMOKE_TEST else "epoch",
    bf16=True,
    gradient_checkpointing=True,  # 2026-08-09：關掉試過會OOM（8GB卡+max_length拉長後撐不住），改回開
    precompute_ref_log_probs=True,  # 參考模型的logp一次算完存起來，訓練迴圈不用每步都多跑一次前向
    # 實測prompt平均2041 token（含世界觀/人格/近期事件），1536會靜默截斷掉大部分——
    # 改成蓋得住的長度，寧可慢一點也不要餵進去的資料本身就是殘缺的
    max_length=2300,
    max_prompt_length=2200,
    report_to=[],
)

bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch.bfloat16,
    bnb_4bit_use_double_quant=True,
)

tokenizer = AutoTokenizer.from_pretrained(MODEL_PATH)
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

model = AutoModelForCausalLM.from_pretrained(
    MODEL_PATH,
    quantization_config=bnb_config,
    device_map="auto",
    torch_dtype=torch.bfloat16,
)

# 2026-08-09：獨立跑這段cast邏輯從來沒失敗過，只有透過DPOTrainer.__init__內部呼叫
# prepare_model_for_kbit_training才會撞"device not ready"（換device_map/bitsandbytes版本/
# 重啟WSL2/調呼叫順序都排除不了，問題出在DPOTrainer.__init__執行到那步之前的某個環節，
# 不是這段cast邏輯本身）。既然自己先跑一遍是通的，改成自己先準備好模型，再把
# DPOTrainer內部會呼叫的同一個函式替換成no-op，跳過那個觸發點，不用等它修好
from peft.utils.other import prepare_model_for_kbit_training
model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=True)
print("手動prepare_model_for_kbit_training成功，繞過DPOTrainer內部呼叫")

import trl.trainer.dpo_trainer as _dpo_trainer_module
_dpo_trainer_module.prepare_model_for_kbit_training = lambda m, **kwargs: m

peft_config = LoraConfig(
    r=16,
    lora_alpha=32,
    lora_dropout=0.05,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    task_type="CAUSAL_LM",
)

trainer = DPOTrainer(
    model=model,
    args=training_args,
    train_dataset=dataset,
    processing_class=tokenizer,
    peft_config=peft_config,
)

trainer.train()
trainer.save_model(OUTPUT_DIR)
print("訓練完成，adapter 存在", OUTPUT_DIR)
