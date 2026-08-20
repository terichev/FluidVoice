# Почему GigaAM v3

> **TL;DR (EN):** This fork adds Sber's [GigaAM v3](https://huggingface.co/ai-sage/GigaAM-v3) as a speech engine because it is the strongest open model for Russian by a wide margin: ~8.4% average WER across Russian benchmarks vs ~25% for Whisper-large-v3, with native punctuation, casing, and number normalization in its e2e variant. It runs fully offline through the local [gigastt](https://github.com/ekhodzitsky/gigastt) server (ONNX Runtime, MIT-licensed model).

## Проблема: русский — «один из» для универсальных моделей

Все штатные движки FluidVoice — многоязычные генералисты, для которых русский лишь один из десятков языков:

- **Parakeet TDT v3** — 25 европейских языков, оптимизирован под скорость;
- **Whisper** — 99 языков;
- **Nemotron Speech 3.5** — ~40 языков;
- **Apple Speech** — системные языки.

Для повседневной русской диктовки это ощущается: путаница в окончаниях, пропуски частиц, слабая пунктуация, галлюцинации Whisper на паузах.

## Решение: специалист вместо генералиста

**GigaAM v3** (Giga Acoustic Model, Сбер) — Conformer-модель на 220–240 млн параметров, предобученная на **700 000 часов русской речи**. Это не «ещё один язык в списке», а модель, целиком построенная вокруг русского. Лицензия — MIT, использовать можно свободно.

### Цифры (WER, ниже — лучше)

Из [карточки модели](https://huggingface.co/ai-sage/GigaAM-v3):

| Датасет | GigaAM v3 RNNT | GigaAM v3 CTC | T-One + LM | Whisper-large-v3 |
| --- | --- | --- | --- | --- |
| Открытые датасеты (Golos, Common Voice, …) | **2.6** | 3.0 | 5.7 | 12.0 |
| Golos Farfield (дальний микрофон) | **3.9** | 4.5 | 12.2 | 16.7 |
| Естественная речь | **6.9** | 7.8 | 14.5 | 13.6 |
| Атипичная речь | **19.2** | 20.6 | 51.0 | 59.3 |
| Колл-центр | **9.5** | 10.3 | 13.5 | 23.9 |
| **Среднее** | **8.4** | 9.2 | 19.4 | 25.1 |

В три раза точнее Whisper-large-v3 на русском — при том, что модель в разы меньше (INT8-бандл ~250 МБ против ~1.5 ГБ у Whisper Large).

### Пунктуация и числа — из самой модели

Используется вариант **e2e_rnnt**: он выдаёт сразу текст с пунктуацией, заглавными буквами и нормализацией чисел («двадцатое августа» → «20 августа»). По оценке LLM-as-a-judge из карточки модели, e2e-вариант выигрывает у Whisper-large-v3 со счётом **70:30**. Для диктовки это значит: не нужен LLM-постпроцессинг, текст готов сразу, задержка минимальна.

## Почему интеграция через gigastt

CoreML-порта GigaAM не существует, поэтому рассматривались три пути:

| Вариант | Плюсы | Минусы |
| --- | --- | --- |
| Конвертировать в CoreML самим | Нативно, как Parakeet | Недели работы: Conformer + RNNT-декодер, поддержка конверсии на нас |
| Встроить ONNX Runtime в приложение | Всё в одном бандле | Тяжёлая нативная зависимость; mel-фронтенд и RNNT-цикл пришлось бы реализовывать и поддерживать в Swift |
| **Локальный сервер [gigastt](https://github.com/ekhodzitsky/gigastt)** ✅ | Готовый поддерживаемый Rust-движок, `brew install`, OpenAI-совместимый API, INT8-модели, CoreML/ANE execution provider | Внешняя зависимость (один `brew install`) |

Выбран gigastt: ~300 строк интеграции вместо тысяч, обновления движка и модели приходят независимо от приложения, и всё по-прежнему работает полностью оффлайн — аудио не покидает Mac (сервер слушает только 127.0.0.1).

Приложение само управляет сервером: запускает `gigastt serve` при активации модели и останавливает при выходе. Настройка и обновления — в [GIGAAM_V3_SETUP.md](GIGAAM_V3_SETUP.md).

## Ссылки

- Модель: [ai-sage/GigaAM-v3](https://huggingface.co/ai-sage/GigaAM-v3) · [salute-developers/GigaAM](https://github.com/salute-developers/GigaAM) · [статья про GigaAM (arXiv)](https://arxiv.org/abs/2506.01192)
- Движок: [ekhodzitsky/gigastt](https://github.com/ekhodzitsky/gigastt)
- Апстрим: [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice)
