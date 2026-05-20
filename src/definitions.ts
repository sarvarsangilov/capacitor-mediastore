// ─────────────────────────────────────────────────────────────────────────────
// CapacitorMediastore Plugin — TypeScript Definitions
// ─────────────────────────────────────────────────────────────────────────────
//
// Плагин делится на две независимые области:
//
//  1) Медиагалерея — фото / видео / аудио, индексированные системой.
//     Источники: MediaStore (Android) и Photos/MPMediaLibrary (iOS).
//     Требует разрешений на чтение медиа.
//
//  2) Файлпикер с «недавними файлами» — произвольные документы (PDF, DOC,
//     ZIP, …), которые пользователь явно выбирает через системный пикер.
//     После выбора плагин сохраняет URI / bookmark в локальном хранилище
//     и гарантирует повторный доступ к этим файлам без повторного запроса
//     у пользователя (persistable URI permission на Android, security-scoped
//     bookmark на iOS).
//
// Никаких MANAGE_EXTERNAL_STORAGE и других «жирных» разрешений плагин
// не требует — приложение проходит ревью обоих сторов без специальных апрувов.
// ─────────────────────────────────────────────────────────────────────────────

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

// ─── Response types ──────────────────────────────────────────────────────────

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
  /** URI / путь к полноразмерному файлу (нативный идентификатор). */
  uri: string;
  /**
   * URL, пригодный для `<img src>` / `<video src>` / `<audio src>` внутри WebView.
   * На Android: `https://localhost/_capacitor_content_/...`
   * На iOS: `capacitor://localhost/_capacitor_file_/tmp/...`
   * На Web: совпадает с `uri`.
   */
  webPath: string | null;
  /** URI миниатюры. В `getMedia` всегда `null` — миниатюра грузится через `getThumbnail`. */
  thumbnailUri: string | null;
  /** URL миниатюры. В `getMedia` всегда `null` — миниатюра грузится через `getThumbnail`. */
  thumbnailWebPath: string | null;
  /** Ширина в пикселях (для аудио — 0). */
  width: number;
  /** Высота в пикселях (для аудио — 0). */
  height: number;
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
  /** Сдвиг для пагинации. */
  offset: number;
  /** Тип медиа: `photo`, `video`, `audio` или `all`. */
  type: MediaType;
}

export interface GetMediaResult {
  media: MediaItem[];
  /** Общее количество медиа, соответствующих фильтру (для пагинации). */
  total: number;
  /** Есть ли ещё элементы после текущей страницы. */
  hasMore: boolean;
}

export interface GetThumbnailOptions {
  /** ID медиафайла. */
  id: string;
  /**
   * Если `true` — дополнительно вернуть `base64String` (legacy / fallback).
   * По умолчанию `false` — возвращается только `webPath`, что в разы быстрее.
   */
  returnBase64?: boolean;
  /** Сторона квадратной миниатюры в пикселях. По умолчанию 256. */
  size?: number;
}

export interface GetThumbnailResult {
  /**
   * URL для `<img src>`. Пустая строка, если миниатюру не удалось сгенерировать
   * (например, для аудио без обложки).
   */
  webPath: string;
  /** Base64-data-URL. Пустая строка, если `returnBase64` не запрошен. */
  base64String: string;
}

export interface GetThumbnailsOptions {
  /** Массив ID медиафайлов. */
  ids: string[];
  /** Сторона квадратной миниатюры в пикселях. По умолчанию 256. */
  size?: number;
}

export interface GetThumbnailsResult {
  /** Словарь `id → webPath`. ID без миниатюры в словаре отсутствуют. */
  thumbnails: Record<string, string>;
}

// ─── File picker / Recent files ──────────────────────────────────────────────

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

// ─── Plugin Interface ────────────────────────────────────────────────────────

export interface CapacitorMediastorePlugin {
  // ── Permissions ────────────────────────────────────────────────────────────

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

  // ── Media gallery ─────────────────────────────────────────────────────────

  /** Возвращает список альбомов фото/видео на устройстве. */
  getAlbums(): Promise<GetAlbumsResult>;

  /**
   * Возвращает список медиафайлов с метаданными (БЕЗ миниатюр).
   * При `type: 'audio'` возвращает треки из системной музыкальной библиотеки.
   */
  getMedia(options: GetMediaOptions): Promise<GetMediaResult>;

  /**
   * Генерирует миниатюру для указанного медиафайла (lazy load).
   * Для аудио возвращает обложку альбома, если она есть; иначе — пустую строку.
   */
  getThumbnail(options: GetThumbnailOptions): Promise<GetThumbnailResult>;

  /**
   * Пакетная генерация миниатюр (lazy load для виртуализированных списков).
   * Один нативный вызов = N миниатюр, чтобы устранить overhead JS-моста.
   */
  getThumbnails(options: GetThumbnailsOptions): Promise<GetThumbnailsResult>;

  // ── File picker & Recent files ────────────────────────────────────────────

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
   * Убирает одну запись из «недавних» и отзывает persistable permission
   * (Android) / удаляет bookmark (iOS). Сам файл на диске НЕ удаляется.
   */
  removeRecentFile(options: RemoveRecentFileOptions): Promise<void>;

  /**
   * Очищает все «недавние» файлы. Отзывает все persistable permissions
   * (Android) / удаляет все bookmarks (iOS). Сами файлы на диске НЕ удаляются.
   */
  clearRecentFiles(): Promise<void>;
}
