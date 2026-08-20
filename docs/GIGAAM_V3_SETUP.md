# GigaAM v3 в FluidVoice — настройка и обновления

Ветка: `feat/gigaam-v3` в [terichev/FluidVoice](https://github.com/terichev/FluidVoice/tree/feat/gigaam-v3). Почему именно эта модель — в [WHY_GIGAAM_V3.md](WHY_GIGAAM_V3.md).

## Что это

В FluidVoice добавлен движок распознавания **«GigaAM v3 (Russian)»** — [модель Сбера](https://huggingface.co/ai-sage/GigaAM-v3), лучшая открытая модель для русской речи. Пунктуация, заглавные буквы и числа («двадцатое августа» → «20 августа») расставляются самой моделью, без AI-постобработки. Всё работает полностью оффлайн.

Live-превью у движка нет — текст появляется по окончании фразы (final-only).

## Как это устроено

```text
FluidVoice (GigaAMProvider)
   │  WAV 16 кГц, POST /v1/audio/transcriptions
   ▼
gigastt serve (127.0.0.1:9876)      ← локальный сервер, ONNX Runtime
   │
   ▼
GigaAM v3 e2e_rnnt (~/.gigastt/models, ~250 МБ)
```

- Провайдер: `Sources/Fluid/Services/GigaAMProvider.swift`. Сам запускает `gigastt serve --model-variant e2e_rnnt`, если сервер не отвечает, и гасит его при выходе из приложения. Вручную сервером управлять не нужно.
- Готовность сервера определяется по `GET /health`: он отвечает 200 сразу, но поле `model` равно `"loading"`, пока модель грузится, и становится именем модели (`gigaam-v3-e2e-rnnt`) по готовности.
- Ответ распознавания: `{"text": "..."}`. Тишина возвращает пустой текст, это норма.
- Вариант модели `e2e_rnnt` — с нативной пунктуацией/капитализацией/нормализацией чисел. Голый `rnnt` (ниже WER, но lowercase без пунктуации) для диктовки не подходит.
- Свой сервер (другой порт/машина): `defaults write com.FluidApp.app.debug gigaamServerURL "http://host:port"`.

## Установка с нуля (новый Mac)

```bash
# 1. Движок gigastt (тап требует доверия — это штатно)
brew tap ekhodzitsky/gigastt https://github.com/ekhodzitsky/gigastt
brew trust ekhodzitsky/gigastt
brew install gigastt

# 2. Модель (можно пропустить — скачается при первом запуске)
gigastt download --model-variant e2e_rnnt

# 3. Приложение — последняя CI-сборка (нужен GitHub CLI: brew install gh)
git clone https://github.com/terichev/FluidVoice.git && cd FluidVoice
./tools/update-app.sh
```

Либо без клонирования: скачай готовый zip со страницы [Releases](https://github.com/terichev/FluidVoice/releases), распакуй в `/Applications` и сними карантин: `xattr -dr com.apple.quarantine "/Applications/FluidVoice Debug.app"`.

Затем в приложении: Settings → Voice Engine → карточка **«GigaAM v3 — Russian»** (категория Sber) → Activate.

## Разрешение Accessibility — важные грабли

- **Не добавляй приложение через кнопку «+»** в Настройках → Универсальный доступ: для ad-hoc-подписанных сборок на macOS 26 этот путь молча не срабатывает.
- Правильный путь: дать **приложению самому** запросить доступ (кнопка в онбординге или первая попытка диктовки) — тогда строка появится в списке сама, останется включить тумблер.
- После **каждого** обновления сборки разрешение нужно выдавать заново: TCC привязывает его к хэшу ad-hoc-подписи, а она меняется при каждой пересборке.
- У debug-сборки отдельный bundle id `com.FluidApp.app.debug` — иначе TCC конфликтует с релизным FluidVoice (`com.FluidApp.app`). Скрипт обновления выставляет его автоматически.

## Обновления

**⚠️ Не пользуйся встроенным «Check for Updates» в debug-сборке** — он установит официальный релиз без GigaAM (в Debug-сборках проверка подписи при обновлении пропускается).

### Обновить свою сборку

```bash
./tools/update-app.sh
```

Скрипт скачивает последний успешный артефакт CI, чинит бандл (симлинки фреймворков ломаются при upload-artifact), ставит debug bundle id, подписывает ad-hoc и устанавливает в `/Applications/FluidVoice Debug.app`.

### Подтянуть новые фичи официального FluidVoice

Для мейнтейнера форка (апстрим — altic-dev/FluidVoice):

```bash
git remote add upstream https://github.com/altic-dev/FluidVoice.git 2>/dev/null
git fetch upstream && git merge upstream/main && git push
# CI соберёт ~10 минут, затем ./tools/update-app.sh
```

Пересборку можно запустить и вручную: `gh workflow run build-app.yml -R terichev/FluidVoice --ref feat/gigaam-v3`.

### Обновить движок и модель

```bash
brew upgrade gigastt        # модели в ~/.gigastt/models обновляются сами при необходимости
```

### Долгосрочный вариант

Открыть PR с GigaAM в апстрим [altic-dev/FluidVoice](https://github.com/altic-dev/FluidVoice). Если примут — модель попадёт в официальные релизы, можно вернуться на обычный FluidVoice с автообновлениями, и вся эта ручная схема станет не нужна.

## Устранение неполадок

| Симптом | Что делать |
| --- | --- |
| Модель не активируется, ошибка про gigastt | Проверь `brew list gigastt`; переустанови при необходимости |
| Долгая активация при первом запуске | Сервер качает модель (~250 МБ) — это одноразово, смотри `curl http://127.0.0.1:9876/health` |
| Приложение не появляется в Универсальном доступе | Не через «+»! Запроси доступ из самого приложения. Если строка «зависла»: `tccutil reset Accessibility com.FluidApp.app.debug`, перезапустить Настройки и приложение |
| Распознавание вернуло пустой текст | Норма для тишины; проверь, что микрофон выбран и уровень сигнала не нулевой |
| Порт 9876 занят чем-то другим | `defaults write com.FluidApp.app.debug gigaamServerURL "http://127.0.0.1:НОВЫЙ_ПОРТ"` и запусти `gigastt serve -p НОВЫЙ_ПОРТ` |

## Ссылки

- Модель: [ai-sage/GigaAM-v3](https://huggingface.co/ai-sage/GigaAM-v3) · [salute-developers/GigaAM](https://github.com/salute-developers/GigaAM)
- Движок: [ekhodzitsky/gigastt](https://github.com/ekhodzitsky/gigastt)
- Ветка с интеграцией: [terichev/FluidVoice · feat/gigaam-v3](https://github.com/terichev/FluidVoice/tree/feat/gigaam-v3)
- CI-сборки: [Actions · Build App Artifact](https://github.com/terichev/FluidVoice/actions/workflows/build-app.yml)
