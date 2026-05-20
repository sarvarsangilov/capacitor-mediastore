import type { PluginListenerHandle } from '@capacitor/core';
/**
 * Тип медиафайла из системной галереи.
 *  - `photo`  — изображение
 *  - `video`  — видео
 *  - `audio`  — аудио / музыка (отдельная коллекция, как «Music» в Telegram)
 *  - `all`    — фото + видео (БЕЗ аудио — для аудио используйте `'audio'`)
 */
export type MediaType = 'photo' | 'video' | 'audio' | 'all';
/**
 * Статус разрешения для конкретного scope.
 *  - `granted`               — полный доступ ко всем медиафайлам данного типа.
 *  - `limited`               — доступ только к выбранным пользователем файлам
 *                              (iOS 14+ для Photos, Android 14+ для visual).
 *  - `denied`                — пользователь отклонил запрос.
 *  - `prompt`                — разрешение ещё не запрашивалось.
 *  - `prompt-with-rationale` — ранее отклонено, можно показать объяснение
 *                              (только Android).
 */
export type PermissionStatus = 'granted' | 'limited' | 'denied' | 'prompt' | 'prompt-with-rationale';
export interface PermissionResult {
    /** Статус разрешения на чтение фото. */
    photos: PermissionStatus;
    /** Статус разрешения на чтение видео. */
    videos: PermissionStatus;
    /** Статус разрешения на чтение аудио / музыки. */
    audio: PermissionStatus;
}
export interface Album {
    /** Уникальный идентификатор альбома. */
    id: string;
    /** Название альбома. */
    title: string;
    /** Количество медиафайлов в альбоме. */
    count: number;
    /** URI / путь обложки альбома (нативный идентификатор). Может быть `null`. */
    coverUri: string | null;
    /** URL обложки, пригодный для `<img src>` внутри WebView (оригинал). */
    coverWebPath: string | null;
    /** URL миниатюры обложки (кэшированный файл ~256px) — для списков. */
    coverThumbnailWebPath: string | null;
}
export interface GetAlbumsResult {
    albums: Album[];
}
export interface MediaItem {
    /** Уникальный идентификатор медиафайла. */
    id: string;
    /** Тип: `photo`, `video` или `audio`. */
    type: 'photo' | 'video' | 'audio';
    /** Нативный URI / путь к полноразмерному файлу. */
    uri: string;
    /**
     * URL для `<img/video/audio src>` внутри WebView.
     *
     * На Android всегда заполнен (это бесплатное преобразование `content://`).
     * На iOS в `getMedia` возвращается `null` для скорости — реальный экспорт
     * фото/видео из `Photos framework` делает [resolveMediaPath] лениво, по
     * требованию (когда пользователь действительно открывает файл).
     */
    webPath: string | null;
    /** URI миниатюры. В `getMedia` всегда `null` — миниатюра грузится через `getThumbnail`. */
    thumbnailUri: string | null;
    /** URL миниатюры. В `getMedia` всегда `null` — миниатюра грузится через `getThumbnail`. */
    thumbnailWebPath: string | null;
    /** Ширина в пикселях с учётом ориентации. Для аудио — 0. */
    width: number;
    /** Высота в пикселях с учётом ориентации. Для аудио — 0. */
    height: number;
    /**
     * Поворот файла в градусах (0, 90, 180, 270).
     * Для видео берётся из EXIF; для фото обычно 0 (Photos / MediaStore сами
     * нормализуют ориентацию при выдаче битмапа).
     */
    orientation: number;
    /**
     * Live Photo (только iOS). На Android всегда `false`.
     * UI может показать badge «LIVE» и проигрывать анимацию по long-press.
     */
    isLivePhoto: boolean;
    /**
     * HDR-фото или Dolby Vision видео (только iOS). На Android всегда `false`.
     */
    isHDR: boolean;
    /** Дата создания (ISO 8601 строка). */
    createdAt: string;
    /** Длительность в секундах (для аудио и видео; 0 для фото). */
    duration: number;
    /** MIME-тип файла. */
    mimeType: string;
    /** Размер файла в байтах. */
    fileSize: number;
    /** Имя файла. */
    fileName: string;
    /** Название трека (заполняется только для `audio`). */
    title?: string;
    /** Исполнитель (заполняется только для `audio`). */
    artist?: string;
    /** Альбом трека (заполняется только для `audio`). */
    album?: string;
}
export interface GetMediaOptions {
    /** ID альбома. Если не передан — возвращает все медиафайлы. */
    albumId?: string;
    /** Максимальное количество элементов. */
    limit: number;
    /** Сдвиг для offset-пагинации. Игнорируется, если передан `cursor`. */
    offset: number;
    /** Тип медиа: `photo`, `video`, `audio` или `all`. */
    type: MediaType;
    /**
     * Курсор для cursor-based пагинации, полученный в `nextCursor` предыдущего
     * ответа. Имеет приоритет над `offset`.
     *
     * Cursor-пагинация даёт **O(log n)** на гигантских галереях (50k+ файлов)
     * против O(offset) у offset-режима. Используйте её для бесконечного скролла.
     *
     * Ограничение: при `type: 'all'` курсор работает не оптимально (внутри
     * мержатся две коллекции) — для очень больших галерей лучше использовать
     * раздельные `photo` / `video` запросы или offset.
     */
    cursor?: string;
}
export interface GetMediaResult {
    media: MediaItem[];
    /** Общее количество медиа, соответствующих фильтру (для пагинации). */
    total: number;
    /** Есть ли ещё элементы после текущей страницы. */
    hasMore: boolean;
    /**
     * Курсор для следующей страницы. `null`, если страница последняя.
     * Передавайте в `cursor` следующего запроса.
     */
    nextCursor: string | null;
}
export interface GetThumbnailOptions {
    /** ID медиафайла. */
    id: string;
    /**
     * Если `true` — дополнительно вернуть `base64String` (legacy / fallback).
     * По умолчанию `false` — возвращается только `webPath`, что в разы быстрее.
     */
    returnBase64?: boolean;
    /** Сторона квадратной миниатюры в DP / PT. По умолчанию 256. */
    size?: number;
    /**
     * Множитель плотности экрана. На 3x-устройствах (iPhone Pro / Pixel)
     * передавайте `window.devicePixelRatio` (обычно 2 или 3), чтобы миниатюра
     * была чёткой, а не размытой при апскейле.
     *
     * Эффективный размер на диске = `size * density`. Кеш именован
     * `thumb_<id>_<size*density>.webp|jpg`.
     *
     * По умолчанию `1`.
     */
    density?: number;
}
export interface GetThumbnailResult {
    /**
     * URL для `<img src>`. Пустая строка, если миниатюру не удалось сгенерировать
     * (например, для аудио без обложки или DRM-track из Apple Music).
     */
    webPath: string;
    /** Base64-data-URL. Пустая строка, если `returnBase64` не запрошен. */
    base64String: string;
}
export interface GetThumbnailsOptions {
    /** Массив ID медиафайлов. */
    ids: string[];
    /** Сторона квадратной миниатюры в DP / PT. По умолчанию 256. */
    size?: number;
    /** Множитель плотности экрана. См. `GetThumbnailOptions.density`. */
    density?: number;
}
export interface GetThumbnailsResult {
    /** Словарь `id → webPath`. ID без миниатюры в словаре отсутствуют. */
    thumbnails: Record<string, string>;
}
export interface HasMediaOptions {
    type: MediaType;
}
export interface HasMediaResult {
    /** `true`, если в выбранной коллекции есть хотя бы один файл. */
    available: boolean;
}
export interface ResolveMediaPathOptions {
    /** ID медиафайла из `MediaItem.id`. */
    id: string;
}
export interface ResolveMediaPathResult {
    /** Нативный URI (тот же, что у `MediaItem.uri`). */
    uri: string;
    /** WebView-URL для `<img/video src>`. `null`, если получить не удалось. */
    webPath: string | null;
}
/**
 * Запись о файле, выбранном пользователем через системный пикер.
 *
 * Плагин сохраняет такие записи в локальном хранилище. На Android повторный
 * доступ обеспечивается через `ContentResolver.takePersistableUriPermission`,
 * на iOS — через security-scoped bookmark.
 */
export interface PickedFile {
    /**
     * Стабильный идентификатор записи в локальном «недавнем» хранилище плагина.
     * Используйте его в [removeRecentFile] и для key-prop в UI.
     * На Android равен закодированному content://-URI; на iOS — UUID bookmark.
     */
    id: string;
    /** Нативный URI (Android: `content://…`; iOS: `file://…`). */
    uri: string;
    /**
     * URL для отображения / скачивания внутри WebView. Получить его повторно
     * можно через [resolveRecentFile] — плагин гарантирует, что доступ к файлу
     * сохранён.
     */
    webPath: string;
    /** Имя файла, отображаемое пользователю. */
    fileName: string;
    /** MIME-тип файла (например `application/pdf`). */
    mimeType: string;
    /** Размер файла в байтах. `0`, если система не вернула размер. */
    fileSize: number;
    /** Дата первого выбора файла через плагин (ISO 8601). */
    pickedAt: string;
    /** Дата последнего успешного доступа к файлу через плагин (ISO 8601). */
    lastAccessedAt: string;
}
export interface PickFilesOptions {
    /**
     * MIME-фильтры, например `['application/pdf', 'image/*']`.
     * По умолчанию пустой массив — разрешены любые файлы (эквивалент `'＊/＊'`).
     */
    mimeTypes?: string[];
    /** Разрешить выбор нескольких файлов. По умолчанию `false`. */
    multiple?: boolean;
}
export interface PickFilesResult {
    /**
     * Выбранные файлы. Пустой массив, если пользователь отменил выбор.
     * Файлы уже добавлены в «недавние» — повторного вызова не требуется.
     */
    files: PickedFile[];
}
export interface GetRecentFilesOptions {
    /** Максимальное количество элементов. По умолчанию 50. */
    limit?: number;
    /** Сдвиг для пагинации. По умолчанию 0. */
    offset?: number;
    /**
     * Фильтр по MIME-типам. Поддерживаются точные значения (`application/pdf`)
     * и wildcards (`image/*`). Если не передан — возвращаются все файлы.
     */
    mimeTypes?: string[];
}
export interface GetRecentFilesResult {
    files: PickedFile[];
    /** Общее количество записей, соответствующих фильтру (для пагинации). */
    total: number;
    /** Есть ли ещё элементы после текущей страницы. */
    hasMore: boolean;
}
export interface RemoveRecentFileOptions {
    /** ID записи (`PickedFile.id`), которую нужно убрать из «недавних». */
    id: string;
}
export interface ResolveRecentFileOptions {
    /** ID записи (`PickedFile.id`), которую нужно повторно открыть. */
    id: string;
}
export interface ResolveRecentFileResult {
    /**
     * Описание файла с обновлённым `webPath` и `lastAccessedAt`,
     * либо `null` если запись больше недоступна (файл удалён, либо
     * пользователь отозвал доступ через системные настройки).
     */
    file: PickedFile | null;
}
export interface ReadFileChunkOptions {
    /** ID записи (`PickedFile.id`). */
    id: string;
    /** Смещение в файле в байтах. По умолчанию 0. */
    offset?: number;
    /**
     * Максимальное количество байт за чтение.
     * По умолчанию 1 МБ (1 048 576). Рекомендуется не превышать 4 МБ,
     * иначе base64-overhead и JS-мост дают заметную задержку.
     */
    length?: number;
}
export interface ReadFileChunkResult {
    /** Прочитанные байты в Base64. */
    data: string;
    /** Реально прочитанное количество байт. Может быть меньше `length` в конце файла. */
    bytesRead: number;
    /** `true`, если достигли конца файла. */
    eof: boolean;
    /** Полный размер файла в байтах (тот же на каждом chunk). */
    totalSize: number;
}
/** Какой тип медиа изменился. */
export type MediaLibraryChangeType = 'photo' | 'video' | 'audio';
export interface MediaLibraryChangeEvent {
    /**
     * Какие коллекции изменились. Из-за дебаунса 500ms одно событие может
     * содержать несколько типов (например, юзер удалил несколько фото и видео
     * подряд).
     */
    types: MediaLibraryChangeType[];
}
export interface CapacitorMediastorePlugin {
    /**
     * Возвращает текущий статус разрешений на доступ к фото / видео / аудио.
     * Не показывает системный диалог — только читает текущее состояние.
     */
    checkPermissions(): Promise<PermissionResult>;
    /**
     * Запрашивает у пользователя разрешения на доступ к фото / видео / аудио.
     * Если разрешение уже выдано — возвращает текущий статус без UI.
     */
    requestPermissions(): Promise<PermissionResult>;
    /** Возвращает список альбомов фото/видео на устройстве. */
    getAlbums(): Promise<GetAlbumsResult>;
    /**
     * Возвращает список медиафайлов с метаданными (БЕЗ миниатюр).
     * При `type: 'audio'` возвращает треки из системной музыкальной библиотеки.
     *
     * Поддерживает два режима пагинации:
     *  - **offset** (поля `limit` / `offset`) — удобно для прыжков в произвольное место.
     *  - **cursor** (поле `cursor`, приоритет над offset) — O(log n) для гигантских галерей.
     */
    getMedia(options: GetMediaOptions): Promise<GetMediaResult>;
    /**
     * Дешёвая проверка: есть ли в коллекции хоть один файл?
     * Используйте на старте приложения, чтобы решить, показывать ли вкладку.
     * Не загружает метаданные.
     */
    hasMedia(options: HasMediaOptions): Promise<HasMediaResult>;
    /**
     * Лениво резолвит `webPath` для `MediaItem` на iOS (на Android всегда
     * заполнен в `getMedia`, метод возвращает уже готовое значение).
     *
     * Под капотом на iOS делает `requestContentEditingInput` /
     * `requestAVAsset` — это **дорогая** операция (экспорт файла во временную
     * папку), поэтому вызывайте только в момент, когда пользователь реально
     * открывает фото / видео.
     */
    resolveMediaPath(options: ResolveMediaPathOptions): Promise<ResolveMediaPathResult>;
    /**
     * Генерирует миниатюру для указанного медиафайла (lazy load).
     * Для аудио возвращает обложку альбома, если она есть; иначе — пустую строку.
     */
    getThumbnail(options: GetThumbnailOptions): Promise<GetThumbnailResult>;
    /**
     * Пакетная генерация миниатюр (lazy load для виртуализированных списков).
     * Один нативный вызов = N миниатюр, чтобы устранить overhead JS-моста.
     *
     * На обеих платформах ограничивает параллелизм (~6 одновременных декодов)
     * и использует кеш `getOrCreateThumbnail*` — повторные запросы того же
     * `id × size × density` отдаются мгновенно.
     */
    getThumbnails(options: GetThumbnailsOptions): Promise<GetThumbnailsResult>;
    /**
     * Прогревает кеш миниатюр в фоне. Возвращается **сразу** (промис резолвится
     * после старта background-задач, не ждёт их завершения).
     *
     * Используйте в виртуализированном списке: при появлении в viewport
     * элементов 100-109 — стрельните prefetch для 110-130, чтобы к моменту
     * скролла туда миниатюры уже были на диске.
     */
    prefetchThumbnails(options: GetThumbnailsOptions): Promise<void>;
    /**
     * Отменяет все pending-задачи на генерацию миниатюр, запущенные через
     * `getThumbnails` / `prefetchThumbnails`. Уже завершённые миниатюры
     * остаются в кеше.
     *
     * Полезно при быстром скролле: на смене страницы отменяете старые
     * запросы и запускаете новые, экономя CPU/батарею.
     */
    cancelPendingThumbnails(): Promise<void>;
    /**
     * Открывает системный пикер файлов (`ACTION_OPEN_DOCUMENT` на Android,
     * `UIDocumentPickerViewController` на iOS) и возвращает выбранные файлы.
     *
     * Выбранные файлы автоматически добавляются в «недавние» — на Android берётся
     * persistable URI permission, на iOS сохраняется security-scoped bookmark.
     * После этого приложение может открывать эти файлы повторно без диалога
     * через [getRecentFiles] / [resolveRecentFile].
     *
     * Если пользователь отменил выбор — возвращается `{ files: [] }` (промис
     * **не** реджектится).
     */
    pickFiles(options?: PickFilesOptions): Promise<PickFilesResult>;
    /**
     * Возвращает «недавние» файлы — те, которые пользователь ранее выбирал
     * через [pickFiles]. Записи отсортированы по `lastAccessedAt DESC`.
     *
     * Плагин на чтении проверяет, что файлы всё ещё доступны (не удалены,
     * не отозваны). Недоступные записи **молча выкидываются** из хранилища.
     */
    getRecentFiles(options?: GetRecentFilesOptions): Promise<GetRecentFilesResult>;
    /**
     * Резолвит конкретную запись из «недавних» — обновляет `webPath` и
     * `lastAccessedAt`. Используйте перед каждым открытием файла, чтобы получить
     * актуальный путь и зафиксировать использование (для сортировки списка).
     *
     * Возвращает `{ file: null }`, если запись больше недоступна.
     */
    resolveRecentFile(options: ResolveRecentFileOptions): Promise<ResolveRecentFileResult>;
    /**
     * Читает фрагмент файла из «недавних» (для streaming-загрузки больших файлов
     * без полной материализации в памяти).
     *
     * Типичный паттерн — загрузить PDF / video по чанкам с прогрессом:
     *
     * ```ts
     * let offset = 0;
     * while (true) {
     *   const chunk = await CapacitorMediastore.readFileChunk({ id, offset, length: 1_000_000 });
     *   // chunk.data — base64, decode и шлём в сеть/IndexedDB
     *   offset += chunk.bytesRead;
     *   if (chunk.eof) break;
     * }
     * ```
     *
     * Без этого метода единственный способ прочитать большой файл — `fetch(webPath)`,
     * который загружает весь файл в память сразу (плохо для 500 МБ видео).
     */
    readFileChunk(options: ReadFileChunkOptions): Promise<ReadFileChunkResult>;
    /**
     * Убирает одну запись из «недавних» и отзывает persistable permission
     * (Android) / удаляет bookmark (iOS). Сам файл на диске НЕ удаляется.
     */
    removeRecentFile(options: RemoveRecentFileOptions): Promise<void>;
    /**
     * Очищает все «недавние» файлы. Отзывает все persistable permissions
     * (Android) / удаляет все bookmarks (iOS). Сами файлы на диске НЕ удаляются.
     */
    clearRecentFiles(): Promise<void>;
    /**
     * Подписка на изменения системной галереи (новые фото, удалённые видео и т.д.).
     * Событие приходит с дебаунсом 500ms, чтобы не спамить при batch-операциях.
     *
     * ```ts
     * const handle = await CapacitorMediastore.addListener(
     *   'mediaLibraryChanged',
     *   ({ types }) => {
     *     if (types.includes('photo')) refreshPhotosTab();
     *   }
     * );
     * // при размонтировании
     * handle.remove();
     * ```
     */
    addListener(eventName: 'mediaLibraryChanged', listenerFunc: (event: MediaLibraryChangeEvent) => void): Promise<PluginListenerHandle>;
    /** Удаляет всех слушателей плагина. */
    removeAllListeners(): Promise<void>;
}
