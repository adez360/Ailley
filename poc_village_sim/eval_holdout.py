"""驗證集評估：用訓練好的LoRA，在完全沒訓練過的資料上算rewards/accuracies跟margins。
2026-08-09。跟train_dpo_money_fail_v2.py用同一套分層抽樣邏輯先重現訓練用掉哪60筆，
剩下的裡面另外抽一批當保留驗證集（同樣分層，公平比較）。
"""
import json
import random

import torch
from peft import PeftModel
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig

MODEL_PATH = "Qwen/Qwen2.5-7B-Instruct"
DATA_PATH = "transcripts/dpo_chosen_money_fail_v2.json"
ADAPTER_PATH = "dpo_output_money_fail_v1"
BETA = 0.1
HOLDOUT_SIZE = 60

with open(DATA_PATH, encoding="utf-8") as f:
    raw = json.load(f)

def to_text(output_obj):
    return json.dumps(output_obj, ensure_ascii=False)

random.seed(20260809)
by_key = {}
for i, r in enumerate(raw):
    by_key.setdefault((r["name"], r["category"]), []).append(i)
keys = list(by_key.keys())
per_key = max(1, 60 // len(keys))
train_idx = []
remaining_by_key = {}
for k in keys:
    idxs = list(by_key[k])
    random.shuffle(idxs)
    train_idx.extend(idxs[:per_key])
    remaining_by_key[k] = idxs[per_key:]
train_idx_set = set(train_idx[:60])
print(f"重現訓練用掉的索引數：{len(train_idx_set)}")

holdout_per_key = max(1, HOLDOUT_SIZE // len(keys))
holdout_idx = []
for k in keys:
    idxs = remaining_by_key[k]
    holdout_idx.extend(idxs[:holdout_per_key])
holdout_idx = holdout_idx[:HOLDOUT_SIZE]
assert not (set(holdout_idx) & train_idx_set), "保留驗證集不該跟訓練集重疊"
print(f"保留驗證集筆數：{len(holdout_idx)}（跟訓練集完全不重疊，已檢查）")

rows = [
    {
        "prompt": raw[i]["prompt"],
        "chosen": to_text(raw[i]["chosen_output"]),
        "rejected": to_text(raw[i]["rejected_output"]),
        "name": raw[i]["name"],
        "category": raw[i]["category"],
    }
    for i in holdout_idx
]

training_args_dummy = None  # 不需要DPOConfig，手動算log-prob就好

bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch.bfloat16,
    bnb_4bit_use_double_quant=True,
)

tokenizer = AutoTokenizer.from_pretrained(MODEL_PATH)
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

base_model = AutoModelForCausalLM.from_pretrained(
    MODEL_PATH, quantization_config=bnb_config, device_map="auto", torch_dtype=torch.bfloat16,
)
model = PeftModel.from_pretrained(base_model, ADAPTER_PATH)
model.eval()
print("模型＋LoRA adapter載入完成")


def seq_logp(prompt_text, completion_text, use_adapter):
    full = prompt_text + completion_text
    prompt_ids = tokenizer(prompt_text, return_tensors="pt").input_ids.to(model.device)
    full_ids = tokenizer(full, return_tensors="pt").input_ids.to(model.device)
    prompt_len = prompt_ids.shape[1]
    if full_ids.shape[1] > 2300:
        full_ids = full_ids[:, :2300]
    ctx = model.disable_adapter() if not use_adapter else _nullcontext()
    with torch.no_grad(), ctx:
        out = model(full_ids)
        logits = out.logits[:, :-1, :]
        labels = full_ids[:, 1:]
        logprobs = torch.log_softmax(logits, dim=-1)
        token_logp = torch.gather(logprobs, 2, labels.unsqueeze(-1)).squeeze(-1)
        completion_logp = token_logp[:, prompt_len - 1:].sum()
    return completion_logp.item()


class _nullcontext:
    def __enter__(self):
        return None
    def __exit__(self, *a):
        return False


results = []
for i, r in enumerate(rows):
    policy_chosen = seq_logp(r["prompt"], r["chosen"], use_adapter=True)
    policy_rejected = seq_logp(r["prompt"], r["rejected"], use_adapter=True)
    ref_chosen = seq_logp(r["prompt"], r["chosen"], use_adapter=False)
    ref_rejected = seq_logp(r["prompt"], r["rejected"], use_adapter=False)

    reward_chosen = BETA * (policy_chosen - ref_chosen)
    reward_rejected = BETA * (policy_rejected - ref_rejected)
    correct = reward_chosen > reward_rejected
    margin = reward_chosen - reward_rejected
    results.append({"name": r["name"], "category": r["category"], "correct": correct, "margin": margin})
    print(f"[{i+1}/{len(rows)}] {r['name']}/{r['category']} correct={correct} margin={margin:.3f}")

accuracy = sum(r["correct"] for r in results) / len(results)
avg_margin = sum(r["margin"] for r in results) / len(results)
print(f"\n===== 保留驗證集結果 =====")
print(f"筆數：{len(results)}")
print(f"rewards/accuracies（保留驗證集）：{accuracy:.4f}")
print(f"rewards/margins（保留驗證集）平均：{avg_margin:.4f}")

by_cat = {}
for r in results:
    by_cat.setdefault(r["category"], []).append(r["correct"])
print("\n分類別準確率：")
for cat, vals in by_cat.items():
    print(f"  {cat}: {sum(vals)}/{len(vals)} = {sum(vals)/len(vals):.2f}")
