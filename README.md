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

### Медиагалерея (фото / видео / аудио)

```typescript
import { CapacitorMediastore } from 'capacitor-mediastore';

// 1. Разрешения
const perm = await CapacitorMediastore.requestPermissions();
// → { photos: 'granted', videos: 'granted', audio: 'granted' }

// 2. Список альбомов фото/видео
const { albums } = await CapacitorMediastore.getAlbums();

// 3. Страница медиа (без миниатюр — для скорости)
const { media, hasMore } = await CapacitorMediastore.getMedia({
  type: 'photo', // 'photo' | 'video' | 'audio' | 'all'
  limit: 50,
  offset: 0,
});

// 4. Lazy-thumbnail для одного айтема
const { webPath } = await CapacitorMediastore.getThumbnail({ id: media[0].id });

// 5. Пакетная генерация миниатюр для виртуализированного списка
const { thumbnails } = await CapacitorMediastore.getThumbnails({
  ids: media.slice(0, 20).map((m) => m.id),
  size: 256,
});
```

Для `type: 'audio'` элементы `MediaItem` дополнительно содержат `title`, `artist`, `album`.
Миниатюра для аудио — это обложка альбома, если она есть в системной библиотеке.

`type: 'all'` возвращает **только** фото + видео (без аудио) — как «общая лента» галереи.
Для аудио используйте отдельный вызов с `type: 'audio'`.

### Файлпикер и «недавние»

```typescript
// 1. Открыть системный пикер. Пользователь выбирает PDF / DOC / ZIP и т.д.
//    После выбора плагин САМ берёт persistable-permission (Android) /
//    создаёт security-scoped bookmark (iOS) и сохраняет запись в локальном
//    хранилище плагина.
const { files } = await CapacitorMediastore.pickFiles({
  mimeTypes: ['application/pdf', 'image/*'],
  multiple: true,
});

// 2. На следующих экранах рисуем свою «вкладку Файлы»
const recent = await CapacitorMediastore.getRecentFiles({
  limit: 50,
  offset: 0,
  // mimeTypes: ['application/pdf'], // опционально
});
// → { files: PickedFile[], total, hasMore }
// Файлы отсортированы по lastAccessedAt DESC.
// Записи, к которым доступ утерян, молча выкидываются из хранилища.

// 3. Перед открытием файла — резолвим (обновляем lastAccessedAt + актуальный webPath)
const { file } = await CapacitorMediastore.resolveRecentFile({ id: recent.files[0].id });
if (file) {
  // <iframe src={file.webPath}> — откроет PDF и т.п.
  // Android webPath: "https://localhost/_capacitor_content_/..."
  // iOS    webPath: "capacitor://localhost/_capacitor_file_/..."
}

// 4. Убрать запись из «недавних» (файл на диске не удаляется)
await CapacitorMediastore.removeRecentFile({ id: recent.files[0].id });

// 5. Очистить весь список
await CapacitorMediastore.clearRecentFiles();
```

### Шаблон «как в Telegram»

UI-вкладки мессенджера обычно строятся так:

| Вкладка | Метод | Источник |
|---|---|---|
| 📷 Галерея | `getMedia({ type: 'all' })` + `getThumbnails` | MediaStore Images/Video (Android), PhotoKit (iOS) |
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

* `getMedia` намеренно **не** возвращает миниатюры — это в десятки раз быстрее на больших галереях.
  Используйте `getThumbnails({ ids })` пакетно при появлении айтемов в видимой области.
* Миниатюры кэшируются на диске (`cacheDir/mediastore_thumbs/`). Повторный запрос
  той же `id × size` отдаёт уже готовый файл без перегенерации.
* На Android `getMedia({ type: 'all' })` использует merge-sort двух уже отсортированных
  курсоров (`Images` и `Video`) без `UNION` — стабильно ~10–50 мс на 50 элементов.
* На iOS `getThumbnails` прогревает `PHCachingImageManager` и ограничивает параллелизм
  декодирования через семафор (6 потоков).
* «Недавние» файлы храним в простом JSON (SharedPreferences на Android, файл в
  Application Support на iOS) — без Room/CoreData, без миграций, операции `O(n)` от
  размера списка (типично десятки записей).

### Подсказки для `<img>`

```html
<img src="${webPath}" loading="lazy" decoding="async" />
```

* По умолчанию миниатюра — 256×256. Если в UI плитки <128 px — передавайте `size: 128`,
  это экономит память.
* `webPath` (file URL) в 5–10× быстрее, чем `data:image/...` base64. Используйте base64
  только когда нужно сохранить миниатюру в IndexedDB или отправить по сети.

## API

<docgen-index>

* [`checkPermissions()`](#checkpermissions)
* [`requestPermissions()`](#requestpermissions)
* [`getAlbums()`](#getalbums)
* [`getMedia(...)`](#getmedia)
* [`getThumbnail(...)`](#getthumbnail)
* [`getThumbnails(...)`](#getthumbnails)
* [`pickFiles(...)`](#pickfiles)
* [`getRecentFiles(...)`](#getrecentfiles)
* [`resolveRecentFile(...)`](#resolverecentfile)
* [`removeRecentFile(...)`](#removerecentfile)
* [`clearRecentFiles()`](#clearrecentfiles)
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

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#getmediaoptions">GetMediaOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getmediaresult">GetMediaResult</a>&gt;</code>

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

| Param         | Type                                                                  |
| ------------- | --------------------------------------------------------------------- |
| **`options`** | <code><a href="#getthumbnailsoptions">GetThumbnailsOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getthumbnailsresult">GetThumbnailsResult</a>&gt;</code>

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

| Prop          | Type                     | Description                                                      |
| ------------- | ------------------------ | ---------------------------------------------------------------- |
| **`media`**   | <code>MediaItem[]</code> |                                                                  |
| **`total`**   | <code>number</code>      | Общее количество медиа, соответствующих фильтру (для пагинации). |
| **`hasMore`** | <code>boolean</code>     | Есть ли ещё элементы после текущей страницы.                     |


#### MediaItem

| Prop                   | Type                                       | Description                                                                                                                                                                                                                                  |
| ---------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`id`**               | <code>string</code>                        | Уникальный идентификатор медиафайла.                                                                                                                                                                                                         |
| **`type`**             | <code>'photo' \| 'video' \| 'audio'</code> | Тип: `photo`, `video` или `audio`.                                                                                                                                                                                                           |
| **`uri`**              | <code>string</code>                        | URI / путь к полноразмерному файлу (нативный идентификатор).                                                                                                                                                                                 |
| **`webPath`**          | <code>string \| null</code>                | URL, пригодный для `&lt;img src&gt;` / `&lt;video src&gt;` / `&lt;audio src&gt;` внутри WebView. На Android: `https://localhost/_capacitor_content_/...` На iOS: `capacitor://localhost/_capacitor_file_/tmp/...` На Web: совпадает с `uri`. |
| **`thumbnailUri`**     | <code>string \| null</code>                | URI миниатюры. В `getMedia` всегда `null` — миниатюра грузится через `getThumbnail`.                                                                                                                                                         |
| **`thumbnailWebPath`** | <code>string \| null</code>                | URL миниатюры. В `getMedia` всегда `null` — миниатюра грузится через `getThumbnail`.                                                                                                                                                         |
| **`width`**            | <code>number</code>                        | Ширина в пикселях (для аудио — 0).                                                                                                                                                                                                           |
| **`height`**           | <code>number</code>                        | Высота в пикселях (для аудио — 0).                                                                                                                                                                                                           |
| **`createdAt`**        | <code>string</code>                        | Дата создания (ISO 8601 строка).                                                                                                                                                                                                             |
| **`duration`**         | <code>number</code>                        | Длительность в секундах (для аудио и видео; 0 для фото).                                                                                                                                                                                     |
| **`mimeType`**         | <code>string</code>                        | MIME-тип файла.                                                                                                                                                                                                                              |
| **`fileSize`**         | <code>number</code>                        | Размер файла в байтах.                                                                                                                                                                                                                       |
| **`fileName`**         | <code>string</code>                        | Имя файла.                                                                                                                                                                                                                                   |
| **`title`**            | <code>string</code>                        | Название трека (заполняется только для `audio`).                                                                                                                                                                                             |
| **`artist`**           | <code>string</code>                        | Исполнитель (заполняется только для `audio`).                                                                                                                                                                                                |
| **`album`**            | <code>string</code>                        | Альбом трека (заполняется только для `audio`).                                                                                                                                                                                               |


#### GetMediaOptions

| Prop          | Type                                            | Description                                              |
| ------------- | ----------------------------------------------- | -------------------------------------------------------- |
| **`albumId`** | <code>string</code>                             | ID альбома. Если не передан — возвращает все медиафайлы. |
| **`limit`**   | <code>number</code>                             | Максимальное количество элементов.                       |
| **`offset`**  | <code>number</code>                             | Сдвиг для пагинации.                                     |
| **`type`**    | <code><a href="#mediatype">MediaType</a></code> | Тип медиа: `photo`, `video`, `audio` или `all`.          |


#### GetThumbnailResult

| Prop               | Type                | Description                                                                                                          |
| ------------------ | ------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **`webPath`**      | <code>string</code> | URL для `&lt;img src&gt;`. Пустая строка, если миниатюру не удалось сгенерировать (например, для аудио без обложки). |
| **`base64String`** | <code>string</code> | Base64-data-URL. Пустая строка, если `returnBase64` не запрошен.                                                     |


#### GetThumbnailOptions

| Prop               | Type                 | Description                                                                                                                                       |
| ------------------ | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`id`**           | <code>string</code>  | ID медиафайла.                                                                                                                                    |
| **`returnBase64`** | <code>boolean</code> | Если `true` — дополнительно вернуть `base64String` (legacy / fallback). По умолчанию `false` — возвращается только `webPath`, что в разы быстрее. |
| **`size`**         | <code>number</code>  | Сторона квадратной миниатюры в пикселях. По умолчанию 256.                                                                                        |


#### GetThumbnailsResult

| Prop             | Type                                                            | Description                                                     |
| ---------------- | --------------------------------------------------------------- | --------------------------------------------------------------- |
| **`thumbnails`** | <code><a href="#record">Record</a>&lt;string, string&gt;</code> | Словарь `id → webPath`. ID без миниатюры в словаре отсутствуют. |


#### GetThumbnailsOptions

| Prop       | Type                  | Description                                                |
| ---------- | --------------------- | ---------------------------------------------------------- |
| **`ids`**  | <code>string[]</code> | Массив ID медиафайлов.                                     |
| **`size`** | <code>number</code>   | Сторона квадратной миниатюры в пикселях. По умолчанию 256. |


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


#### RemoveRecentFileOptions

| Prop     | Type                | Description                                                                                |
| -------- | ------------------- | ------------------------------------------------------------------------------------------ |
| **`id`** | <code>string</code> | ID записи (<a href="#pickedfile">`PickedFile.id`</a>), которую нужно убрать из «недавних». |


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

</docgen-api>
