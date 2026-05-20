# capacitor-mediastore

Capacitor 8.x плагин для доступа к медиагалерее устройства (фото / видео / аудио) и системному пикеру произвольных файлов с гарантированным повторным доступом к ранее выбранным файлам.

Плагин состоит из двух независимых блоков:

1. **Медиагалерея** — фото, видео и аудио из системных коллекций.
   Источники: `MediaStore` (Android), `Photos framework` + `MPMediaLibrary` (iOS).
2. **Файлпикер с «недавними файлами»** — системный пикер для документов (PDF, DOC, ZIP, …)
   с пожизненным доступом к выбранным файлам: `takePersistableUriPermission` (Android) и
   `security-scoped bookmark` (iOS). После первого выбора приложение может открывать
   файл повторно без диалога — как «недавние» в Telegram / WhatsApp.

Никаких `MANAGE_EXTERNAL_STORAGE` и других «жирных» разрешений плагин не использует —
приложение пройдёт ревью в Google Play и App Store без специальных апрувов.

## Установка

```bash
npm install capacitor-mediastore
npx cap sync
```

## Платформенные требования

### Android

`AndroidManifest.xml` плагина уже включает нужные разрешения. Минимальный API уровень — 24 (Android 7.0).
Плагин сам подбирает корректный набор пермишенов под версию ОС:

* **Android 13+ (API 33+)** — `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `READ_MEDIA_AUDIO`
* **Android 14+ (API 34+)** — `READ_MEDIA_VISUAL_USER_SELECTED` для partial-доступа к фото/видео
* **Android 10–12 (API 29–32)** — `READ_EXTERNAL_STORAGE` (с `maxSdkVersion=32`)

Файлпикер (`pickFiles`) **никаких** runtime-разрешений не требует — он использует
`ACTION_OPEN_DOCUMENT`, который отдаёт URI с пожизненным правом чтения.

### iOS

Добавьте в `Info.plist` хост-приложения:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Для отображения ваших фото и видео в чатах</string>

<key>NSAppleMusicUsageDescription</key>
<string>Для отправки музыки из вашей библиотеки</string>
```

`NSAppleMusicUsageDescription` нужен для доступа к аудио через `MPMediaLibrary`.
Без него `requestPermissions()` для `audio` всегда будет возвращать `denied`.

Минимальная версия iOS — 15.0.

## Использование

### Базовый поток

```typescript
import { CapacitorMediastore } from 'capacitor-mediastore';

// 1. Разрешения
const perm = await CapacitorMediastore.requestPermissions();
// → { photos: 'granted', videos: 'granted', audio: 'granted' }

// 2. Быстрая проверка перед показом вкладок (~миллисекунда, не грузит метаданные)
const audioAvailable = (await CapacitorMediastore.hasMedia({ type: 'audio' })).available;

// 3. Страница медиа БЕЗ миниатюр (для скорости)
const { media, nextCursor } = await CapacitorMediastore.getMedia({
  type: 'photo', // 'photo' | 'video' | 'audio' | 'all'
  limit: 50,
  offset: 0,
});

// 4. Пакетная генерация миниатюр для виртуализированного списка
const { thumbnails } = await CapacitorMediastore.getThumbnails({
  ids: media.slice(0, 20).map((m) => m.id),
  size: 256,
  density: window.devicePixelRatio, // ⭐ для чёткости на Retina/3x
});

// 5. Прогрев кеша вперёд по скроллу (НЕ ждём результата)
CapacitorMediastore.prefetchThumbnails({
  ids: media.slice(20, 60).map((m) => m.id),
  size: 256,
  density: window.devicePixelRatio,
});

// 6. Когда пользователь открыл конкретное фото — резолвим тяжёлый webPath
const { webPath } = await CapacitorMediastore.resolveMediaPath({ id: media[0].id });
// На iOS это вызывает экспорт через requestContentEditingInput,
// на Android просто возвращает уже готовый content://-путь.
```

### Cursor-based пагинация (для гигантских галерей)

Для галерей **50k+ файлов** offset-пагинация деградирует — `OFFSET 10000 LIMIT 50` заставляет БД пропустить 10000 строк. Cursor-режим даёт **O(log n)**:

```typescript
let cursor: string | null = null;
const allItems: MediaItem[] = [];

while (true) {
  const page = await CapacitorMediastore.getMedia({
    type: 'photo',
    limit: 50,
    offset: 0, // игнорируется при наличии cursor
    cursor: cursor ?? undefined,
  });
  allItems.push(...page.media);
  if (!page.hasMore) break;
  cursor = page.nextCursor;
}
```

Cursor — это base64-токен, опаковый для клиента. Не парсите его, просто передавайте обратно.

### Density для Retina / 3x-экранов

UI-плитка 100dp на iPhone 14 Pro Max — это **300 физических пикселей**. Миниатюра 256×256 при отображении в такой плитке апскейлится и **визуально замыливается**. Передавайте `density: window.devicePixelRatio`:

```typescript
const dpr = window.devicePixelRatio; // 2 или 3 на современных девайсах
const { webPath } = await CapacitorMediastore.getThumbnail({
  id,
  size: 100,      // желаемый размер плитки в DP/CSS-пикселях
  density: dpr,   // → реальный файл будет 200×200 или 300×300
});
```

Кеш именован `thumb_<id>_<size*density>.webp` (Android) / `.jpg` (iOS), так что один файл — одна плотность; разные плотности кешируются параллельно.

### Отмена pending-задач при быстром скролле

При быстром скролле списка нет смысла декодировать миниатюры для уже-проскроленных элементов:

```typescript
// При смене страницы / большом scroll velocity
await CapacitorMediastore.cancelPendingThumbnails();
// затем запрашиваем новый набор
await CapacitorMediastore.getThumbnails({ ids: nowVisibleIds, ... });
```

Уже сохранённые на диске миниатюры остаются в кеше — отменяются только in-flight запросы. На iOS отменяется через `PHImageManager.cancelImageRequest`, на Android — через `Job.cancel()`.

### Авто-обновление при изменениях галереи

```typescript
const handle = await CapacitorMediastore.addListener(
  'mediaLibraryChanged',
  ({ types }) => {
    if (types.includes('photo')) refreshPhotosTab();
    if (types.includes('audio')) refreshMusicTab();
  }
);

// при unmount
await handle.remove();
```

События дебаунсятся 500ms, чтобы batch-операции (удаление 50 фото скриптом) генерили одно событие. Подписка на Android — `ContentObserver` на `MediaStore.Images/Video/Audio`. На iOS — `PHPhotoLibraryChangeObserver` + `MPMediaLibraryDidChange` Notification.

### Live Photo / HDR / ориентация

`MediaItem` теперь включает:

```typescript
{
  // ...
  orientation: 0 | 90 | 180 | 270,  // для видео — из EXIF; для фото обычно 0
  isLivePhoto: boolean,              // iOS only
  isHDR: boolean,                    // iOS only
}
```

UI может показать badge «LIVE» на Live Photos и заранее повернуть видео-плеер под нужную ориентацию (без «прыжка» при загрузке метаданных).

### Файлпикер и «недавние»

```typescript
// 1. Открыть системный пикер. Пользователь выбирает PDF / DOC / ZIP и т.д.
const { files } = await CapacitorMediastore.pickFiles({
  mimeTypes: ['application/pdf', 'image/*'],
  multiple: true,
});

// 2. На следующих экранах рисуем свою «вкладку Файлы»
const recent = await CapacitorMediastore.getRecentFiles({
  limit: 50,
  offset: 0,
});

// 3. Перед открытием файла — резолвим (актуальный webPath + bump lastAccessedAt)
const { file } = await CapacitorMediastore.resolveRecentFile({ id: recent.files[0].id });
if (file) {
  // <iframe src={file.webPath}>
}

// 4. Streaming-чтение больших файлов (PDF 500MB, видео и т.д.)
let offset = 0;
const chunkSize = 1_048_576; // 1 MB
while (true) {
  const chunk = await CapacitorMediastore.readFileChunk({
    id: file!.id, offset, length: chunkSize,
  });
  // chunk.data — base64. Decode и пишем в IndexedDB / шлём в сеть с прогрессом.
  offset += chunk.bytesRead;
  updateProgress(offset / chunk.totalSize);
  if (chunk.eof) break;
}

// 5. Управление
await CapacitorMediastore.removeRecentFile({ id });
await CapacitorMediastore.clearRecentFiles();
```

`readFileChunk` решает проблему «как загрузить 1 ГБ видео не повесив webview» — `fetch(webPath)` грузит весь файл в память сразу, что плохо. Streaming читает по чанкам прямо с диска под security-scoped access.

### Шаблон «как в Telegram»

UI-вкладки мессенджера обычно строятся так:

| Вкладка | Метод | Источник |
|---|---|---|
| 📷 Галерея | `getMedia({ type: 'all' })` + `getThumbnails` + `prefetchThumbnails` | MediaStore Images/Video (Android), PhotoKit (iOS) |
| 🎵 Музыка | `getMedia({ type: 'audio' })` | MediaStore.Audio (Android), MPMediaLibrary (iOS) |
| 📄 Файлы | `getRecentFiles()` + кнопка «+» → `pickFiles()` | Plugin-storage с persistable URI / bookmark |

Каждая вкладка независима, каждая использует ровно один метод плагина.
Никакого `MANAGE_EXTERNAL_STORAGE` — приложение проходит ревью в Google Play без специальных апрувов.

## Гарантии повторного доступа к файлам

**Android.** При `pickFiles()` плагин вызывает
`contentResolver.takePersistableUriPermission(uri, FLAG_GRANT_READ_URI_PERMISSION)`.
Доступ сохраняется **на всё время жизни приложения** и переживает перезапуски устройства.
Доступ теряется только если:

* пользователь явно отзывает его через **Настройки → Приложения → Хранилище**;
* файл удалён из источника;
* приложение переустановлено (URI становятся невалидными).

Во всех случаях `getRecentFiles()` молча отфильтровывает мёртвые записи.

**iOS.** При `pickFiles()` плагин делает
`url.bookmarkData(options: .minimalBookmark, ...)` и сохраняет bookmark в
`Application Support/CapacitorMediastore/recent_files.json`. При повторном чтении
bookmark резолвится через `URL(resolvingBookmarkData:)` с проверкой `isStale` — если
файл переехал, bookmark **автоматически пересоздаётся**. Доступ теряется только если:

* файл удалён;
* пользователь отозвал доступ через приложение «Файлы»;
* приложение переустановлено (bookmark теряет привязку).

## Производительность

Цель — приближение к UX нативных галерей iOS Photos / Google Photos. Что для этого сделано:

* **WebP-миниатюры на Android** (на 25–30% меньше JPEG, быстрее декодирование).
* **Семафор-throttling**: на обеих платформах ≤6 одновременных декодов миниатюр.
  Не перегружает IO-пул и не вызывает jank при скролле.
* **Async callbacks на iOS** вместо `DispatchSemaphore.wait()` — нет блокировки
  потоков GCD, нет starvation при медленных iCloud-сетях.
* **Lazy webPath**: в `getMedia` на iOS не делаем дорогой экспорт через
  `requestContentEditingInput` для каждого элемента — это происходит лениво в
  `resolveMediaPath` только когда юзер открыл конкретный файл.
* **`PHCachingImageManager` warmup** перед `getThumbnails`, плюс отдельный
  `prefetchThumbnails` для прогрева вне списка.
* **Cancellation**: отмена через `PHImageManager.cancelImageRequest` /
  `kotlinx.coroutines.Job.cancel()`. При быстром скролле не тратим CPU на
  невидимые элементы.
* **Cursor-pagination**: `O(log n)` против `O(offset)` для гигантских галерей.
* **Density-aware thumbnails**: миниатюры сохраняются в физических пикселях, без
  размытия при апскейле на Retina/3x.
* **Дисковый кеш** в `cacheDir/mediastore_thumbs/`. Повторный запрос
  `id × size × density` отдаётся мгновенно. Система сама чистит при нехватке места.
* **«Недавние» — простой JSON** (SharedPreferences на Android, файл в Application
  Support на iOS). Без Room/CoreData, без миграций.

### Подсказки для `<img>`

```html
<img src="${webPath}" loading="lazy" decoding="async" />
```

* По умолчанию миниатюра — 256×256 (DP). Передавайте `density: window.devicePixelRatio`
  для чёткости на Retina.
* `webPath` (file URL) в 5–10× быстрее, чем `data:image/...` base64. Используйте base64
  только когда нужно сохранить миниатюру в IndexedDB или отправить по сети.

## API

<docgen-index>

* [`checkPermissions()`](#checkpermissions)
* [`requestPermissions()`](#requestpermissions)
* [`getAlbums()`](#getalbums)
* [`getMedia(...)`](#getmedia)
* [`hasMedia(...)`](#hasmedia)
* [`resolveMediaPath(...)`](#resolvemediapath)
* [`getThumbnail(...)`](#getthumbnail)
* [`getThumbnails(...)`](#getthumbnails)
* [`prefetchThumbnails(...)`](#prefetchthumbnails)
* [`cancelPendingThumbnails()`](#cancelpendingthumbnails)
* [`pickFiles(...)`](#pickfiles)
* [`getRecentFiles(...)`](#getrecentfiles)
* [`resolveRecentFile(...)`](#resolverecentfile)
* [`readFileChunk(...)`](#readfilechunk)
* [`removeRecentFile(...)`](#removerecentfile)
* [`clearRecentFiles()`](#clearrecentfiles)
* [`addListener('mediaLibraryChanged', ...)`](#addlistenermedialibrarychanged-)
* [`removeAllListeners()`](#removealllisteners)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### checkPermissions()

```typescript
checkPermissions() => Promise<PermissionResult>
```

Возвращает текущий статус разрешений на доступ к фото / видео / аудио.
Не показывает системный диалог — только читает текущее состояние.

**Returns:** <code>Promise&lt;<a href="#permissionresult">PermissionResult</a>&gt;</code>

--------------------


### requestPermissions()

```typescript
requestPermissions() => Promise<PermissionResult>
```

Запрашивает у пользователя разрешения на доступ к фото / видео / аудио.
Если разрешение уже выдано — возвращает текущий статус без UI.

**Returns:** <code>Promise&lt;<a href="#permissionresult">PermissionResult</a>&gt;</code>

--------------------


### getAlbums()

```typescript
getAlbums() => Promise<GetAlbumsResult>
```

Возвращает список альбомов фото/видео на устройстве.

**Returns:** <code>Promise&lt;<a href="#getalbumsresult">GetAlbumsResult</a>&gt;</code>

--------------------


### getMedia(...)

```typescript
getMedia(options: GetMediaOptions) => Promise<GetMediaResult>
```

Возвращает список медиафайлов с метаданными (БЕЗ миниатюр).
При `type: 'audio'` возвращает треки из системной музыкальной библиотеки.

Поддерживает два режима пагинации:
 - **offset** (поля `limit` / `offset`) — удобно для прыжков в произвольное место.
 - **cursor** (поле `cursor`, приоритет над offset) — O(log n) для гигантских галерей.

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#getmediaoptions">GetMediaOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getmediaresult">GetMediaResult</a>&gt;</code>

--------------------


### hasMedia(...)

```typescript
hasMedia(options: HasMediaOptions) => Promise<HasMediaResult>
```

Дешёвая проверка: есть ли в коллекции хоть один файл?
Используйте на старте приложения, чтобы решить, показывать ли вкладку.
Не загружает метаданные.

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#hasmediaoptions">HasMediaOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#hasmediaresult">HasMediaResult</a>&gt;</code>

--------------------


### resolveMediaPath(...)

```typescript
resolveMediaPath(options: ResolveMediaPathOptions) => Promise<ResolveMediaPathResult>
```

Лениво резолвит `webPath` для <a href="#mediaitem">`MediaItem`</a> на iOS (на Android всегда
заполнен в `getMedia`, метод возвращает уже готовое значение).

Под капотом на iOS делает `requestContentEditingInput` /
`requestAVAsset` — это **дорогая** операция (экспорт файла во временную
папку), поэтому вызывайте только в момент, когда пользователь реально
открывает фото / видео.

| Param         | Type                                                                        |
| ------------- | --------------------------------------------------------------------------- |
| **`options`** | <code><a href="#resolvemediapathoptions">ResolveMediaPathOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#resolvemediapathresult">ResolveMediaPathResult</a>&gt;</code>

--------------------


### getThumbnail(...)

```typescript
getThumbnail(options: GetThumbnailOptions) => Promise<GetThumbnailResult>
```

Генерирует миниатюру для указанного медиафайла (lazy load).
Для аудио возвращает обложку альбома, если она есть; иначе — пустую строку.

| Param         | Type                                                                |
| ------------- | ------------------------------------------------------------------- |
| **`options`** | <code><a href="#getthumbnailoptions">GetThumbnailOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getthumbnailresult">GetThumbnailResult</a>&gt;</code>

--------------------


### getThumbnails(...)

```typescript
getThumbnails(options: GetThumbnailsOptions) => Promise<GetThumbnailsResult>
```

Пакетная генерация миниатюр (lazy load для виртуализированных списков).
Один нативный вызов = N миниатюр, чтобы устранить overhead JS-моста.

На обеих платформах ограничивает параллелизм (~6 одновременных декодов)
и использует кеш `getOrCreateThumbnail*` — повторные запросы того же
`id × size × density` отдаются мгновенно.

| Param         | Type                                                                  |
| ------------- | --------------------------------------------------------------------- |
| **`options`** | <code><a href="#getthumbnailsoptions">GetThumbnailsOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getthumbnailsresult">GetThumbnailsResult</a>&gt;</code>

--------------------


### prefetchThumbnails(...)

```typescript
prefetchThumbnails(options: GetThumbnailsOptions) => Promise<void>
```

Прогревает кеш миниатюр в фоне. Возвращается **сразу** (промис резолвится
после старта background-задач, не ждёт их завершения).

Используйте в виртуализированном списке: при появлении в viewport
элементов 100-109 — стрельните prefetch для 110-130, чтобы к моменту
скролла туда миниатюры уже были на диске.

| Param         | Type                                                                  |
| ------------- | --------------------------------------------------------------------- |
| **`options`** | <code><a href="#getthumbnailsoptions">GetThumbnailsOptions</a></code> |

--------------------


### cancelPendingThumbnails()

```typescript
cancelPendingThumbnails() => Promise<void>
```

Отменяет все pending-задачи на генерацию миниатюр, запущенные через
`getThumbnails` / `prefetchThumbnails`. Уже завершённые миниатюры
остаются в кеше.

Полезно при быстром скролле: на смене страницы отменяете старые
запросы и запускаете новые, экономя CPU/батарею.

--------------------


### pickFiles(...)

```typescript
pickFiles(options?: PickFilesOptions | undefined) => Promise<PickFilesResult>
```

Открывает системный пикер файлов (`ACTION_OPEN_DOCUMENT` на Android,
`UIDocumentPickerViewController` на iOS) и возвращает выбранные файлы.

Выбранные файлы автоматически добавляются в «недавние» — на Android берётся
persistable URI permission, на iOS сохраняется security-scoped bookmark.
После этого приложение может открывать эти файлы повторно без диалога
через [getRecentFiles] / [resolveRecentFile].

Если пользователь отменил выбор — возвращается `{ files: [] }` (промис
**не** реджектится).

| Param         | Type                                                          |
| ------------- | ------------------------------------------------------------- |
| **`options`** | <code><a href="#pickfilesoptions">PickFilesOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#pickfilesresult">PickFilesResult</a>&gt;</code>

--------------------


### getRecentFiles(...)

```typescript
getRecentFiles(options?: GetRecentFilesOptions | undefined) => Promise<GetRecentFilesResult>
```

Возвращает «недавние» файлы — те, которые пользователь ранее выбирал
через [pickFiles]. Записи отсортированы по `lastAccessedAt DESC`.

Плагин на чтении проверяет, что файлы всё ещё доступны (не удалены,
не отозваны). Недоступные записи **молча выкидываются** из хранилища.

| Param         | Type                                                                    |
| ------------- | ----------------------------------------------------------------------- |
| **`options`** | <code><a href="#getrecentfilesoptions">GetRecentFilesOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getrecentfilesresult">GetRecentFilesResult</a>&gt;</code>

--------------------


### resolveRecentFile(...)

```typescript
resolveRecentFile(options: ResolveRecentFileOptions) => Promise<ResolveRecentFileResult>
```

Резолвит конкретную запись из «недавних» — обновляет `webPath` и
`lastAccessedAt`. Используйте перед каждым открытием файла, чтобы получить
актуальный путь и зафиксировать использование (для сортировки списка).

Возвращает `{ file: null }`, если запись больше недоступна.

| Param         | Type                                                                          |
| ------------- | ----------------------------------------------------------------------------- |
| **`options`** | <code><a href="#resolverecentfileoptions">ResolveRecentFileOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#resolverecentfileresult">ResolveRecentFileResult</a>&gt;</code>

--------------------


### readFileChunk(...)

```typescript
readFileChunk(options: ReadFileChunkOptions) => Promise<ReadFileChunkResult>
```

Читает фрагмент файла из «недавних» (для streaming-загрузки больших файлов
без полной материализации в памяти).

Типичный паттерн — загрузить PDF / video по чанкам с прогрессом:

```ts
let offset = 0;
while (true) {
  const chunk = await CapacitorMediastore.readFileChunk({ id, offset, length: 1_000_000 });
  // chunk.data — base64, decode и шлём в сеть/IndexedDB
  offset += chunk.bytesRead;
  if (chunk.eof) break;
}
```

Без этого метода единственный способ прочитать большой файл — `fetch(webPath)`,
который загружает весь файл в память сразу (плохо для 500 МБ видео).

| Param         | Type                                                                  |
| ------------- | --------------------------------------------------------------------- |
| **`options`** | <code><a href="#readfilechunkoptions">ReadFileChunkOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#readfilechunkresult">ReadFileChunkResult</a>&gt;</code>

--------------------


### removeRecentFile(...)

```typescript
removeRecentFile(options: RemoveRecentFileOptions) => Promise<void>
```

Убирает одну запись из «недавних» и отзывает persistable permission
(Android) / удаляет bookmark (iOS). Сам файл на диске НЕ удаляется.

| Param         | Type                                                                        |
| ------------- | --------------------------------------------------------------------------- |
| **`options`** | <code><a href="#removerecentfileoptions">RemoveRecentFileOptions</a></code> |

--------------------


### clearRecentFiles()

```typescript
clearRecentFiles() => Promise<void>
```

Очищает все «недавние» файлы. Отзывает все persistable permissions
(Android) / удаляет все bookmarks (iOS). Сами файлы на диске НЕ удаляются.

--------------------


### addListener('mediaLibraryChanged', ...)

```typescript
addListener(eventName: 'mediaLibraryChanged', listenerFunc: (event: MediaLibraryChangeEvent) => void) => Promise<PluginListenerHandle>
```

Подписка на изменения системной галереи (новые фото, удалённые видео и т.д.).
Событие приходит с дебаунсом 500ms, чтобы не спамить при batch-операциях.

```ts
const handle = await CapacitorMediastore.addListener(
  'mediaLibraryChanged',
  ({ types }) =&gt; {
    if (types.includes('photo')) refreshPhotosTab();
  }
);
// при размонтировании
handle.remove();
```

| Param              | Type                                                                                            |
| ------------------ | ----------------------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'mediaLibraryChanged'</code>                                                              |
| **`listenerFunc`** | <code>(event: <a href="#medialibrarychangeevent">MediaLibraryChangeEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

--------------------


### removeAllListeners()

```typescript
removeAllListeners() => Promise<void>
```

Удаляет всех слушателей плагина.

--------------------


### Interfaces


#### PermissionResult

| Prop         | Type                                                          | Description                                 |
| ------------ | ------------------------------------------------------------- | ------------------------------------------- |
| **`photos`** | <code><a href="#permissionstatus">PermissionStatus</a></code> | Статус разрешения на чтение фото.           |
| **`videos`** | <code><a href="#permissionstatus">PermissionStatus</a></code> | Статус разрешения на чтение видео.          |
| **`audio`**  | <code><a href="#permissionstatus">PermissionStatus</a></code> | Статус разрешения на чтение аудио / музыки. |


#### GetAlbumsResult

| Prop         | Type                 |
| ------------ | -------------------- |
| **`albums`** | <code>Album[]</code> |


#### Album

| Prop                        | Type                        | Description                                                             |
| --------------------------- | --------------------------- | ----------------------------------------------------------------------- |
| **`id`**                    | <code>string</code>         | Уникальный идентификатор альбома.                                       |
| **`title`**                 | <code>string</code>         | Название альбома.                                                       |
| **`count`**                 | <code>number</code>         | Количество медиафайлов в альбоме.                                       |
| **`coverUri`**              | <code>string \| null</code> | URI / путь обложки альбома (нативный идентификатор). Может быть `null`. |
| **`coverWebPath`**          | <code>string \| null</code> | URL обложки, пригодный для `&lt;img src&gt;` внутри WebView (оригинал). |
| **`coverThumbnailWebPath`** | <code>string \| null</code> | URL миниатюры обложки (кэшированный файл ~256px) — для списков.         |


#### GetMediaResult

| Prop             | Type                        | Description                                                                                                |
| ---------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **`media`**      | <code>MediaItem[]</code>    |                                                                                                            |
| **`total`**      | <code>number</code>         | Общее количество медиа, соответствующих фильтру (для пагинации).                                           |
| **`hasMore`**    | <code>boolean</code>        | Есть ли ещё элементы после текущей страницы.                                                               |
| **`nextCursor`** | <code>string \| null</code> | Курсор для следующей страницы. `null`, если страница последняя. Передавайте в `cursor` следующего запроса. |


#### MediaItem

| Prop                   | Type                                       | Description                                                                                                                                                                                                                                                                                                                                |
| ---------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`id`**               | <code>string</code>                        | Уникальный идентификатор медиафайла.                                                                                                                                                                                                                                                                                                       |
| **`type`**             | <code>'photo' \| 'video' \| 'audio'</code> | Тип: `photo`, `video` или `audio`.                                                                                                                                                                                                                                                                                                         |
| **`uri`**              | <code>string</code>                        | Нативный URI / путь к полноразмерному файлу.                                                                                                                                                                                                                                                                                               |
| **`webPath`**          | <code>string \| null</code>                | URL для `&lt;img/video/audio src&gt;` внутри WebView. На Android всегда заполнен (это бесплатное преобразование `content://`). На iOS в `getMedia` возвращается `null` для скорости — реальный экспорт фото/видео из `Photos framework` делает [resolveMediaPath] лениво, по требованию (когда пользователь действительно открывает файл). |
| **`thumbnailUri`**     | <code>string \| null</code>                | URI миниатюры. В `getMedia` всегда `null` — миниатюра грузится через `getThumbnail`.                                                                                                                                                                                                                                                       |
| **`thumbnailWebPath`** | <code>string \| null</code>                | URL миниатюры. В `getMedia` всегда `null` — миниатюра грузится через `getThumbnail`.                                                                                                                                                                                                                                                       |
| **`width`**            | <code>number</code>                        | Ширина в пикселях с учётом ориентации. Для аудио — 0.                                                                                                                                                                                                                                                                                      |
| **`height`**           | <code>number</code>                        | Высота в пикселях с учётом ориентации. Для аудио — 0.                                                                                                                                                                                                                                                                                      |
| **`orientation`**      | <code>number</code>                        | Поворот файла в градусах (0, 90, 180, 270). Для видео берётся из EXIF; для фото обычно 0 (Photos / MediaStore сами нормализуют ориентацию при выдаче битмапа).                                                                                                                                                                             |
| **`isLivePhoto`**      | <code>boolean</code>                       | Live Photo (только iOS). На Android всегда `false`. UI может показать badge «LIVE» и проигрывать анимацию по long-press.                                                                                                                                                                                                                   |
| **`isHDR`**            | <code>boolean</code>                       | HDR-фото или Dolby Vision видео (только iOS). На Android всегда `false`.                                                                                                                                                                                                                                                                   |
| **`createdAt`**        | <code>string</code>                        | Дата создания (ISO 8601 строка).                                                                                                                                                                                                                                                                                                           |
| **`duration`**         | <code>number</code>                        | Длительность в секундах (для аудио и видео; 0 для фото).                                                                                                                                                                                                                                                                                   |
| **`mimeType`**         | <code>string</code>                        | MIME-тип файла.                                                                                                                                                                                                                                                                                                                            |
| **`fileSize`**         | <code>number</code>                        | Размер файла в байтах.                                                                                                                                                                                                                                                                                                                     |
| **`fileName`**         | <code>string</code>                        | Имя файла.                                                                                                                                                                                                                                                                                                                                 |
| **`title`**            | <code>string</code>                        | Название трека (заполняется только для `audio`).                                                                                                                                                                                                                                                                                           |
| **`artist`**           | <code>string</code>                        | Исполнитель (заполняется только для `audio`).                                                                                                                                                                                                                                                                                              |
| **`album`**            | <code>string</code>                        | Альбом трека (заполняется только для `audio`).                                                                                                                                                                                                                                                                                             |


#### GetMediaOptions

| Prop          | Type                                            | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------- | ----------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`albumId`** | <code>string</code>                             | ID альбома. Если не передан — возвращает все медиафайлы.                                                                                                                                                                                                                                                                                                                                                                                                       |
| **`limit`**   | <code>number</code>                             | Максимальное количество элементов.                                                                                                                                                                                                                                                                                                                                                                                                                             |
| **`offset`**  | <code>number</code>                             | Сдвиг для offset-пагинации. Игнорируется, если передан `cursor`.                                                                                                                                                                                                                                                                                                                                                                                               |
| **`type`**    | <code><a href="#mediatype">MediaType</a></code> | Тип медиа: `photo`, `video`, `audio` или `all`.                                                                                                                                                                                                                                                                                                                                                                                                                |
| **`cursor`**  | <code>string</code>                             | Курсор для cursor-based пагинации, полученный в `nextCursor` предыдущего ответа. Имеет приоритет над `offset`. Cursor-пагинация даёт **O(log n)** на гигантских галереях (50k+ файлов) против O(offset) у offset-режима. Используйте её для бесконечного скролла. Ограничение: при `type: 'all'` курсор работает не оптимально (внутри мержатся две коллекции) — для очень больших галерей лучше использовать раздельные `photo` / `video` запросы или offset. |


#### HasMediaResult

| Prop            | Type                 | Description                                                |
| --------------- | -------------------- | ---------------------------------------------------------- |
| **`available`** | <code>boolean</code> | `true`, если в выбранной коллекции есть хотя бы один файл. |


#### HasMediaOptions

| Prop       | Type                                            |
| ---------- | ----------------------------------------------- |
| **`type`** | <code><a href="#mediatype">MediaType</a></code> |


#### ResolveMediaPathResult

| Prop          | Type                        | Description                                                                |
| ------------- | --------------------------- | -------------------------------------------------------------------------- |
| **`uri`**     | <code>string</code>         | Нативный URI (тот же, что у <a href="#mediaitem">`MediaItem.uri`</a>).     |
| **`webPath`** | <code>string \| null</code> | WebView-URL для `&lt;img/video src&gt;`. `null`, если получить не удалось. |


#### ResolveMediaPathOptions

| Prop     | Type                | Description                                               |
| -------- | ------------------- | --------------------------------------------------------- |
| **`id`** | <code>string</code> | ID медиафайла из <a href="#mediaitem">`MediaItem.id`</a>. |


#### GetThumbnailResult

| Prop               | Type                | Description                                                                                                                                       |
| ------------------ | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`webPath`**      | <code>string</code> | URL для `&lt;img src&gt;`. Пустая строка, если миниатюру не удалось сгенерировать (например, для аудио без обложки или DRM-track из Apple Music). |
| **`base64String`** | <code>string</code> | Base64-data-URL. Пустая строка, если `returnBase64` не запрошен.                                                                                  |


#### GetThumbnailOptions

| Prop               | Type                 | Description                                                                                                                                                                                                                                                                                                           |
| ------------------ | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`id`**           | <code>string</code>  | ID медиафайла.                                                                                                                                                                                                                                                                                                        |
| **`returnBase64`** | <code>boolean</code> | Если `true` — дополнительно вернуть `base64String` (legacy / fallback). По умолчанию `false` — возвращается только `webPath`, что в разы быстрее.                                                                                                                                                                     |
| **`size`**         | <code>number</code>  | Сторона квадратной миниатюры в DP / PT. По умолчанию 256.                                                                                                                                                                                                                                                             |
| **`density`**      | <code>number</code>  | Множитель плотности экрана. На 3x-устройствах (iPhone Pro / Pixel) передавайте `window.devicePixelRatio` (обычно 2 или 3), чтобы миниатюра была чёткой, а не размытой при апскейле. Эффективный размер на диске = `size * density`. Кеш именован `thumb_&lt;id&gt;_&lt;size*density&gt;.webp\|jpg`. По умолчанию `1`. |


#### GetThumbnailsResult

| Prop             | Type                                                            | Description                                                     |
| ---------------- | --------------------------------------------------------------- | --------------------------------------------------------------- |
| **`thumbnails`** | <code><a href="#record">Record</a>&lt;string, string&gt;</code> | Словарь `id → webPath`. ID без миниатюры в словаре отсутствуют. |


#### GetThumbnailsOptions

| Prop          | Type                  | Description                                                                                       |
| ------------- | --------------------- | ------------------------------------------------------------------------------------------------- |
| **`ids`**     | <code>string[]</code> | Массив ID медиафайлов.                                                                            |
| **`size`**    | <code>number</code>   | Сторона квадратной миниатюры в DP / PT. По умолчанию 256.                                         |
| **`density`** | <code>number</code>   | Множитель плотности экрана. См. <a href="#getthumbnailoptions">`GetThumbnailOptions.density`</a>. |


#### PickFilesResult

| Prop        | Type                      | Description                                                                                                                         |
| ----------- | ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **`files`** | <code>PickedFile[]</code> | Выбранные файлы. Пустой массив, если пользователь отменил выбор. Файлы уже добавлены в «недавние» — повторного вызова не требуется. |


#### PickedFile

Запись о файле, выбранном пользователем через системный пикер.

Плагин сохраняет такие записи в локальном хранилище. На Android повторный
доступ обеспечивается через `ContentResolver.takePersistableUriPermission`,
на iOS — через security-scoped bookmark.

| Prop                 | Type                | Description                                                                                                                                                                                                  |
| -------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **`id`**             | <code>string</code> | Стабильный идентификатор записи в локальном «недавнем» хранилище плагина. Используйте его в [removeRecentFile] и для key-prop в UI. На Android равен закодированному content://-URI; на iOS — UUID bookmark. |
| **`uri`**            | <code>string</code> | Нативный URI (Android: `content://…`; iOS: `file://…`).                                                                                                                                                      |
| **`webPath`**        | <code>string</code> | URL для отображения / скачивания внутри WebView. Получить его повторно можно через [resolveRecentFile] — плагин гарантирует, что доступ к файлу сохранён.                                                    |
| **`fileName`**       | <code>string</code> | Имя файла, отображаемое пользователю.                                                                                                                                                                        |
| **`mimeType`**       | <code>string</code> | MIME-тип файла (например `application/pdf`).                                                                                                                                                                 |
| **`fileSize`**       | <code>number</code> | Размер файла в байтах. `0`, если система не вернула размер.                                                                                                                                                  |
| **`pickedAt`**       | <code>string</code> | Дата первого выбора файла через плагин (ISO 8601).                                                                                                                                                           |
| **`lastAccessedAt`** | <code>string</code> | Дата последнего успешного доступа к файлу через плагин (ISO 8601).                                                                                                                                           |


#### PickFilesOptions

| Prop            | Type                  | Description                                                                                                                       |
| --------------- | --------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **`mimeTypes`** | <code>string[]</code> | MIME-фильтры, например `['application/pdf', 'image/*']`. По умолчанию пустой массив — разрешены любые файлы (эквивалент `'＊/＊'`). |
| **`multiple`**  | <code>boolean</code>  | Разрешить выбор нескольких файлов. По умолчанию `false`.                                                                          |


#### GetRecentFilesResult

| Prop          | Type                      | Description                                                        |
| ------------- | ------------------------- | ------------------------------------------------------------------ |
| **`files`**   | <code>PickedFile[]</code> |                                                                    |
| **`total`**   | <code>number</code>       | Общее количество записей, соответствующих фильтру (для пагинации). |
| **`hasMore`** | <code>boolean</code>      | Есть ли ещё элементы после текущей страницы.                       |


#### GetRecentFilesOptions

| Prop            | Type                  | Description                                                                                                                                 |
| --------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| **`limit`**     | <code>number</code>   | Максимальное количество элементов. По умолчанию 50.                                                                                         |
| **`offset`**    | <code>number</code>   | Сдвиг для пагинации. По умолчанию 0.                                                                                                        |
| **`mimeTypes`** | <code>string[]</code> | Фильтр по MIME-типам. Поддерживаются точные значения (`application/pdf`) и wildcards (`image/*`). Если не передан — возвращаются все файлы. |


#### ResolveRecentFileResult

| Prop       | Type                                                      | Description                                                                                                                                                                     |
| ---------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`file`** | <code><a href="#pickedfile">PickedFile</a> \| null</code> | Описание файла с обновлённым `webPath` и `lastAccessedAt`, либо `null` если запись больше недоступна (файл удалён, либо пользователь отозвал доступ через системные настройки). |


#### ResolveRecentFileOptions

| Prop     | Type                | Description                                                                            |
| -------- | ------------------- | -------------------------------------------------------------------------------------- |
| **`id`** | <code>string</code> | ID записи (<a href="#pickedfile">`PickedFile.id`</a>), которую нужно повторно открыть. |


#### ReadFileChunkResult

| Prop            | Type                 | Description                                                                    |
| --------------- | -------------------- | ------------------------------------------------------------------------------ |
| **`data`**      | <code>string</code>  | Прочитанные байты в Base64.                                                    |
| **`bytesRead`** | <code>number</code>  | Реально прочитанное количество байт. Может быть меньше `length` в конце файла. |
| **`eof`**       | <code>boolean</code> | `true`, если достигли конца файла.                                             |
| **`totalSize`** | <code>number</code>  | Полный размер файла в байтах (тот же на каждом chunk).                         |


#### ReadFileChunkOptions

| Prop         | Type                | Description                                                                                                                                                     |
| ------------ | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`id`**     | <code>string</code> | ID записи (<a href="#pickedfile">`PickedFile.id`</a>).                                                                                                          |
| **`offset`** | <code>number</code> | Смещение в файле в байтах. По умолчанию 0.                                                                                                                      |
| **`length`** | <code>number</code> | Максимальное количество байт за чтение. По умолчанию 1 МБ (1 048 576). Рекомендуется не превышать 4 МБ, иначе base64-overhead и JS-мост дают заметную задержку. |


#### RemoveRecentFileOptions

| Prop     | Type                | Description                                                                                |
| -------- | ------------------- | ------------------------------------------------------------------------------------------ |
| **`id`** | <code>string</code> | ID записи (<a href="#pickedfile">`PickedFile.id`</a>), которую нужно убрать из «недавних». |


#### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


#### MediaLibraryChangeEvent

| Prop        | Type                                  | Description                                                                                                                                          |
| ----------- | ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`types`** | <code>MediaLibraryChangeType[]</code> | Какие коллекции изменились. Из-за дебаунса 500ms одно событие может содержать несколько типов (например, юзер удалил несколько фото и видео подряд). |


### Type Aliases


#### PermissionStatus

Статус разрешения для конкретного scope.
 - `granted`               — полный доступ ко всем медиафайлам данного типа.
 - `limited`               — доступ только к выбранным пользователем файлам
                             (iOS 14+ для Photos, Android 14+ для visual).
 - `denied`                — пользователь отклонил запрос.
 - `prompt`                — разрешение ещё не запрашивалось.
 - `prompt-with-rationale` — ранее отклонено, можно показать объяснение
                             (только Android).

<code>'granted' | 'limited' | 'denied' | 'prompt' | 'prompt-with-rationale'</code>


#### MediaType

Тип медиафайла из системной галереи.
 - `photo`  — изображение
 - `video`  — видео
 - `audio`  — аудио / музыка (отдельная коллекция, как «Music» в Telegram)
 - `all`    — фото + видео (БЕЗ аудио — для аудио используйте `'audio'`)

<code>'photo' | 'video' | 'audio' | 'all'</code>


#### Record

Construct a type with a set of properties K of type T

<code>{ [P in K]: T; }</code>


#### MediaLibraryChangeType

Какой тип медиа изменился.

<code>'photo' | 'video' | 'audio'</code>

</docgen-api>
