# Looktok local VTON worker (Stage C eval bench)

CatVTON on Apple Silicon / MPS, served over FastAPI on port **8123**.

> **Лицензия — читать до запуска.** CatVTON (и OOTDiffusion) — CC BY-NC-SA:
> некоммерческая. Этот воркер — исследовательский бенч для оценки качества и
> латентности локального VTON перед тренировкой СВОИХ весов (Stage C).
> Подключать его к продовому трафику Looktok нельзя.

## Установка (M1 Pro, 16 GB)

```bash
cd "vton-local"
python3 -m venv .venv && source .venv/bin/activate      # arm64 python, не rosetta
pip install -r requirements.txt

# пайплайн-класс берём из репозитория CatVTON (клонится рядом с main.py)
git clone https://github.com/Zheng-Chong/CatVTON.git
```

## Веса

Скачиваются сами при первом старте в `~/.cache/huggingface`:

| Что | Репо | Размер |
|---|---|---|
| База SD1.5-inpainting | `booksforcharlie/stable-diffusion-inpainting` | ~4 GB |
| CatVTON attention-модули (mix: VITON-HD + DressCode) | `zhengchong/CatVTON` | ~400 MB |

Вручную ничего качать не нужно. Если хочется прогреть заранее:

```bash
python -c "from huggingface_hub import snapshot_download as d; d('zhengchong/CatVTON'); d('booksforcharlie/stable-diffusion-inpainting')"
```

## Запуск

```bash
PYTORCH_ENABLE_MPS_FALLBACK=1 uvicorn main:app --host 0.0.0.0 --port 8123
```

`PYTORCH_ENABLE_MPS_FALLBACK=1` обязателен: пара операций SD-пайплайна не
реализована на MPS и уходит на CPU вместо падения.

## Проверка

```bash
curl -s http://localhost:8123/health
curl -s -X POST http://localhost:8123/generate \
  -F "avatar=@avatar.png" \
  -F "garment=@tee.jpg" \
  -F "category=upper_body" \
  -o result.jpg && open result.jpg
```

`category`: `upper_body` | `lower_body` | `overall`.

## Что ожидать на M1 Pro

- fp16 на `mps`, вход жмётся до 768×1024 — пик памяти ~10–12 GB
  (закрой Chrome/Xcode при первом прогоне);
- ~60–120 секунд на рендер при 30 шагах (это бенч качества, не скорости —
  продовая цель Stage C это те же веса на serverless 4090, ~2–4 c);
- маска: для канонического аватара (серые бейсики) строится хром-порогом —
  тем же, что в grid-vton; для уличных фото падает на прямоугольную зону.

## Куда это ведёт

Если качество на наших луках устраивает → тренируем собственные веса той же
архитектуры (см. project-план Stage C, брейк-евен ~650 рендеров/день) и
выкатываем за тем же контрактом, что grid-vton. Этот воркер тогда становится
локальным стендом регрессий.
