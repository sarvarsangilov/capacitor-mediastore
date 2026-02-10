# capacitor-mediastore

CapacitorMediastore Capacitor Plugin

## Install

```bash
npm install capacitor-mediastore
npx cap sync
```

## API

<docgen-index>

* [`checkPermissions()`](#checkpermissions)
* [`requestPermissions()`](#requestpermissions)
* [`getAlbums()`](#getalbums)
* [`getMedia(...)`](#getmedia)
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

Возвращает список медиафайлов с метаданными, поддерживает пагинацию и фильтрацию.

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#getmediaoptions">GetMediaOptions</a></code> |

**Returns:** <code>Promise&lt;<a href="#getmediaresult">GetMediaResult</a>&gt;</code>

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

| Prop               | Type                        | Description                                                               |
| ------------------ | --------------------------- | ------------------------------------------------------------------------- |
| **`id`**           | <code>string</code>         | Уникальный идентификатор альбома                                          |
| **`title`**        | <code>string</code>         | Название альбома                                                          |
| **`count`**        | <code>number</code>         | Количество медиафайлов в альбоме                                          |
| **`coverUri`**     | <code>string \| null</code> | URI / путь обложки альбома (нативный идентификатор). Может быть `null`.   |
| **`coverWebPath`** | <code>string \| null</code> | URL обложки, пригодный для использования в &lt;img src&gt; внутри WebView |


#### GetMediaResult

| Prop          | Type                     | Description                                                     |
| ------------- | ------------------------ | --------------------------------------------------------------- |
| **`media`**   | <code>MediaItem[]</code> |                                                                 |
| **`total`**   | <code>number</code>      | Общее количество медиа, соответствующих фильтру (для пагинации) |
| **`hasMore`** | <code>boolean</code>     | Есть ли ещё элементы после текущей страницы                     |


#### MediaItem

| Prop               | Type                            | Description                                                                                                                                                                                                                 |
| ------------------ | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`id`**           | <code>string</code>             | Уникальный идентификатор медиафайла                                                                                                                                                                                         |
| **`type`**         | <code>'photo' \| 'video'</code> | Тип: photo или video                                                                                                                                                                                                        |
| **`uri`**          | <code>string</code>             | URI / путь к полноразмерному файлу (нативный идентификатор)                                                                                                                                                                 |
| **`webPath`**      | <code>string \| null</code>     | URL, пригодный для использования в &lt;img src&gt; / &lt;video src&gt; внутри WebView. На Android: http://localhost/_capacitor_content_/... На iOS: capacitor://localhost/_capacitor_file_/tmp/... На Web: совпадает с uri. |
| **`thumbnailUri`** | <code>string \| null</code>     | URI / base64 миниатюры (может быть null, если не удалось получить)                                                                                                                                                          |
| **`width`**        | <code>number</code>             | Ширина в пикселях                                                                                                                                                                                                           |
| **`height`**       | <code>number</code>             | Высота в пикселях                                                                                                                                                                                                           |
| **`createdAt`**    | <code>string</code>             | Дата создания (ISO 8601 строка)                                                                                                                                                                                             |
| **`duration`**     | <code>number</code>             | Длительность в секундах (только для видео, 0 для фото)                                                                                                                                                                      |
| **`mimeType`**     | <code>string</code>             | MIME-тип файла                                                                                                                                                                                                              |
| **`fileSize`**     | <code>number</code>             | Размер файла в байтах                                                                                                                                                                                                       |
| **`fileName`**     | <code>string</code>             | Имя файла                                                                                                                                                                                                                   |


#### GetMediaOptions

| Prop          | Type                                            | Description                                              |
| ------------- | ----------------------------------------------- | -------------------------------------------------------- |
| **`albumId`** | <code>string</code>                             | ID альбома. Если не передан — возвращает все медиафайлы. |
| **`limit`**   | <code>number</code>                             | Максимальное количество элементов                        |
| **`offset`**  | <code>number</code>                             | Сдвиг для пагинации                                      |
| **`type`**    | <code><a href="#mediatype">MediaType</a></code> | Тип медиа: 'photo', 'video' или 'all'                    |


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

</docgen-api>
