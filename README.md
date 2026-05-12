# capacitor-mediastore

CapacitorMediastore Capacitor Plugin — быстрый доступ к медиагалерее устройства из Capacitor (Android / iOS / Web).

## Install

```bash
npm install capacitor-mediastore
npx cap sync
```

## Performance / как не тормозить webview

Плагин спроектирован под виртуализированные списки превью. Ключевые принципы:

1. **`getMedia` НЕ возвращает миниатюры** (`thumbnailWebPath = null`) — это сознательная оптимизация. Подгружайте превью лениво, по мере появления элемента в viewport.
2. **Используйте `webPath`, а не base64.** `getThumbnail` по умолчанию отдаёт `webPath` — путь к закешированному JPEG, который webview грузит нативно. Это в 5–10× быстрее `data:`-URL и не раздувает DOM:

   ```ts
   const { webPath } = await CapacitorMediastore.getThumbnail({ id });
   imgEl.src = webPath; // нативный кеш браузера, без копирования через JS-мост
   ```

   Если по каким-то причинам нужна base64-строка (например, для inline-аватарок в IndexedDB), запросите явно:

   ```ts
   const { base64String } = await CapacitorMediastore.getThumbnail({ id, returnBase64: true });
   ```

3. **Группируйте запросы через `getThumbnails`.** Один нативный вызов на пачку видимых элементов вместо N round-trip'ов:

   ```ts
   // visibleIds — id'шники медиа, которые сейчас в viewport
   const { thumbnails } = await CapacitorMediastore.getThumbnails({ ids: visibleIds, size: 256 });
   visibleIds.forEach(id => {
     const img = domMap.get(id);
     if (img && thumbnails[id]) img.src = thumbnails[id];
   });
   ```

4. **Подсказки для `<img>`:** используйте `loading="lazy" decoding="async"` — webview сам решает, когда декодировать:

   ```html
   <img src="${webPath}" loading="lazy" decoding="async" />
   ```

5. **Размер миниатюры:** по умолчанию 256×256. Если в UI плитки <128 px — передавайте `size: 128`, это экономит память.
6. **Android** запускает все методы в `Dispatchers.IO`, не блокируя bridge-поток. **iOS** использует `PHCachingImageManager` с прогревом кеша для пакетных запросов.
7. **Кеш миниатюр** живёт в `cacheDir/mediastore_thumbs/` (Android) и `Caches/mediastore_thumbs/` (iOS). Система сама очистит его при нехватке места — вручную чистить не нужно.

## API

<docgen-index>

* [`checkPermissions()`](#checkpermissions)
* [`requestPermissions()`](#requestpermissions)
* [`getAlbums()`](#getalbums)
* [`getMedia(...)`](#getmedia)
* [`getThumbnail(...)`](#getthumbnail)
* [`getThumbnails(...)`](#getthumbnails)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### checkPermissions()

```typescript
checkPermissions() => Promise<PermissionResult>
```

Проверяет текущий статус разрешений на доступ к медиагалерее.

**Returns:** <code>Promise&lt;<a href="#permissionresult">PermissionResult</a>&gt;</code>

--------------------


### requestPermissions()

```typescript
requestPermissions() => Promise<PermissionResult>
```

Запрашивает у пользователя разрешения на доступ к медиагалерее.

**Returns:** <code>Promise&lt;<a href="#permissionresult">PermissionResult</a>&gt;</code>

--------------------


### getAlbums()

```typescript
getAlbums() => Promise<GetAlbumsResult>
```

Возвращает список альбомов на устройстве.

**Returns:** <code>Promise&lt;<a href="#getalbumsresult">GetAlbumsResult</a>&gt;</code>

--------------------


### getMedia(...)

```typescript
getMedia(options: GetMediaOptions) => Promise<GetMediaResult>
```

Возвращает список медиафайлов с метаданными (БЕЗ миниатюр).

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#getmediaoptions">GetMediaOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getmediaresult">GetMediaResult</a>&gt;</code>

--------------------


### getThumbnail(...)

```typescript
getThumbnail(options: GetThumbnailOptions) => Promise<GetThumbnailResult>
```

Генерирует миниатюру для указанного медиафайла (Lazy Load).
По умолчанию возвращает `webPath` (file URL), что значительно быстрее, чем Base64.

| Param         | Type                                                                |
| ------------- | ------------------------------------------------------------------- |
| **`options`** | <code><a href="#getthumbnailoptions">GetThumbnailOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getthumbnailresult">GetThumbnailResult</a>&gt;</code>

--------------------


### getThumbnails(...)

```typescript
getThumbnails(options: GetThumbnailsOptions) => Promise<GetThumbnailsResult>
```

Пакетная генерация миниатюр (Lazy Load для виртуализированных списков).
Один нативный вызов = N миниатюр, что устраняет overhead на JS-мост.

| Param         | Type                                                                  |
| ------------- | --------------------------------------------------------------------- |
| **`options`** | <code><a href="#getthumbnailsoptions">GetThumbnailsOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getthumbnailsresult">GetThumbnailsResult</a>&gt;</code>

--------------------


### Interfaces


#### PermissionResult

| Prop         | Type                                                          | Description                       |
| ------------ | ------------------------------------------------------------- | --------------------------------- |
| **`photos`** | <code><a href="#permissionstatus">PermissionStatus</a></code> | Статус разрешения на чтение фото  |
| **`videos`** | <code><a href="#permissionstatus">PermissionStatus</a></code> | Статус разрешения на чтение видео |


#### GetAlbumsResult

| Prop         | Type                 |
| ------------ | -------------------- |
| **`albums`** | <code>Album[]</code> |


#### Album

| Prop                        | Type                        | Description                                                                           |
| --------------------------- | --------------------------- | ------------------------------------------------------------------------------------- |
| **`id`**                    | <code>string</code>         | Уникальный идентификатор альбома                                                      |
| **`title`**                 | <code>string</code>         | Название альбома                                                                      |
| **`count`**                 | <code>number</code>         | Количество медиафайлов в альбоме                                                      |
| **`coverUri`**              | <code>string \| null</code> | URI / путь обложки альбома (нативный идентификатор). Может быть `null`.               |
| **`coverWebPath`**          | <code>string \| null</code> | URL обложки, пригодный для использования в &lt;img src&gt; внутри WebView (оригинал)  |
| **`coverThumbnailWebPath`** | <code>string \| null</code> | URL миниатюры обложки (кэшированный файл ~256px), высокопроизводительный, для списков |


#### GetMediaResult

| Prop          | Type                     | Description                                                     |
| ------------- | ------------------------ | --------------------------------------------------------------- |
| **`media`**   | <code>MediaItem[]</code> |                                                                 |
| **`total`**   | <code>number</code>      | Общее количество медиа, соответствующих фильтру (для пагинации) |
| **`hasMore`** | <code>boolean</code>     | Есть ли ещё элементы после текущей страницы                     |


#### MediaItem

| Prop                   | Type                            | Description                                                                                                                                                                                                                  |
| ---------------------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`id`**               | <code>string</code>             | Уникальный идентификатор медиафайла                                                                                                                                                                                          |
| **`type`**             | <code>'photo' \| 'video'</code> | Тип: photo или video                                                                                                                                                                                                         |
| **`uri`**              | <code>string</code>             | URI / путь к полноразмерному файлу (нативный идентификатор)                                                                                                                                                                  |
| **`webPath`**          | <code>string \| null</code>     | URL, пригодный для использования в &lt;img src&gt; / &lt;video src&gt; внутри WebView. На Android: https://localhost/_capacitor_content_/... На iOS: capacitor://localhost/_capacitor_file_/tmp/... На Web: совпадает с uri. |
| **`thumbnailUri`**     | <code>string \| null</code>     | URI / base64 миниатюры (в getMedia теперь возвращается null для производительности)                                                                                                                                          |
| **`thumbnailWebPath`** | <code>string \| null</code>     | URL миниатюры (в getMedia теперь возвращается null для производительности)                                                                                                                                                   |
| **`width`**            | <code>number</code>             | Ширина в пикселях                                                                                                                                                                                                            |
| **`height`**           | <code>number</code>             | Высота в пикселях                                                                                                                                                                                                            |
| **`createdAt`**        | <code>string</code>             | Дата создания (ISO 8601 строка)                                                                                                                                                                                              |
| **`duration`**         | <code>number</code>             | Длительность в секундах (только для видео, 0 для фото)                                                                                                                                                                       |
| **`mimeType`**         | <code>string</code>             | MIME-тип файла                                                                                                                                                                                                               |
| **`fileSize`**         | <code>number</code>             | Размер файла в байтах                                                                                                                                                                                                        |
| **`fileName`**         | <code>string</code>             | Имя файла                                                                                                                                                                                                                    |


#### GetMediaOptions

| Prop          | Type                                            | Description                                              |
| ------------- | ----------------------------------------------- | -------------------------------------------------------- |
| **`albumId`** | <code>string</code>                             | ID альбома. Если не передан — возвращает все медиафайлы. |
| **`limit`**   | <code>number</code>                             | Максимальное количество элементов                        |
| **`offset`**  | <code>number</code>                             | Сдвиг для пагинации                                      |
| **`type`**    | <code><a href="#mediatype">MediaType</a></code> | Тип медиа: 'photo', 'video' или 'all'                    |


#### GetThumbnailResult

| Prop               | Type                | Description                                                                                                                                                                                                   |
| ------------------ | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`webPath`**      | <code>string</code> | URL для использования в `&lt;img src&gt;` (`https://localhost/_capacitor_file_/...` на Android, `capacitor://localhost/_capacitor_file_/...` на iOS). Пустая строка, если миниатюру не удалось сгенерировать. |
| **`base64String`** | <code>string</code> | Base64-data-URL (`data:image/jpeg;base64,...`). Пустая строка, если `returnBase64` не был запрошен.                                                                                                           |


#### GetThumbnailOptions

| Prop               | Type                 | Description                                                                                                                                       |
| ------------------ | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`id`**           | <code>string</code>  | ID медиафайла                                                                                                                                     |
| **`returnBase64`** | <code>boolean</code> | Если `true` — дополнительно вернуть `base64String` (legacy / fallback). По умолчанию `false` — возвращается только `webPath`, что в разы быстрее. |
| **`size`**         | <code>number</code>  | Сторона квадратной миниатюры в пикселях. По умолчанию 256.                                                                                        |


#### GetThumbnailsResult

| Prop             | Type                                                            | Description                                                                                           |
| ---------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| **`thumbnails`** | <code><a href="#record">Record</a>&lt;string, string&gt;</code> | Словарь: `id` → `webPath`. ID, для которых миниатюру не удалось сгенерировать, в словаре отсутствуют. |


#### GetThumbnailsOptions

| Prop       | Type                  | Description                                                |
| ---------- | --------------------- | ---------------------------------------------------------- |
| **`ids`**  | <code>string[]</code> | Массив ID медиафайлов                                      |
| **`size`** | <code>number</code>   | Сторона квадратной миниатюры в пикселях. По умолчанию 256. |


### Type Aliases


#### PermissionStatus

Статус разрешения для конкретного scope.
 - `granted`  — полный доступ ко всем медиафайлам.
 - `limited`  — доступ только к выбранным пользователем файлам (iOS 14+ / Android 14+).
 - `denied`   — пользователь отклонил запрос.
 - `prompt`   — разрешение ещё не запрашивалось.
 - `prompt-with-rationale` — ранее отклонено, но можно показать объяснение (Android).

<code>'granted' | 'limited' | 'denied' | 'prompt' | 'prompt-with-rationale'</code>


#### MediaType

Тип медиафайла.

<code>'photo' | 'video' | 'all'</code>


#### Record

Construct a type with a set of properties K of type T

<code>{ [P in K]: T; }</code>

</docgen-api>
