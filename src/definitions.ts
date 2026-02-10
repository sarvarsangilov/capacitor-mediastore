// ─────────────────────────────────────────────────────────────────────────────
// MediaGallery Plugin — TypeScript Definitions
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Тип медиафайла.
 */
export type MediaType = 'photo' | 'video' | 'all';

/**
 * Статус разрешения для конкретного scope.
 *  - `granted`  — полный доступ ко всем медиафайлам.
 *  - `limited`  — доступ только к выбранным пользователем файлам (iOS 14+ / Android 14+).
 *  - `denied`   — пользователь отклонил запрос.
 *  - `prompt`   — разрешение ещё не запрашивалось.
 *  - `prompt-with-rationale` — ранее отклонено, но можно показать объяснение (Android).
 */
export type PermissionStatus = 'granted' | 'limited' | 'denied' | 'prompt' | 'prompt-with-rationale';

// ─── Response types ──────────────────────────────────────────────────────────

export interface PermissionResult {
  /** Статус разрешения на чтение фото */
  photos: PermissionStatus;
  /** Статус разрешения на чтение видео */
  videos: PermissionStatus;
}

export interface Album {
  /** Уникальный идентификатор альбома */
  id: string;
  /** Название альбома */
  title: string;
  /** Количество медиафайлов в альбоме */
  count: number;
  /** URI / путь обложки альбома (нативный идентификатор). Может быть `null`. */
  coverUri: string | null;
  /** URL обложки, пригодный для использования в <img src> внутри WebView (оригинал) */
  coverWebPath: string | null;
  /** URL миниатюры обложки (кэшированный файл ~300px), высокопроизводительный, для списков */
  coverThumbnailWebPath: string | null;
}

export interface GetAlbumsResult {
  albums: Album[];
}

export interface MediaItem {
  /** Уникальный идентификатор медиафайла */
  id: string;
  /** Тип: photo или video */
  type: 'photo' | 'video';
  /** URI / путь к полноразмерному файлу (нативный идентификатор) */
  uri: string;
  /**
   * URL, пригодный для использования в <img src> / <video src> внутри WebView.
   * На Android: http://localhost/_capacitor_content_/...
   * На iOS: capacitor://localhost/_capacitor_file_/tmp/...
   * На Web: совпадает с uri.
   */
  webPath: string | null;
  /** URI / base64 миниатюры (в getMedia теперь возвращается null для производительности) */
  thumbnailUri: string | null;
  /** URL миниатюры (в getMedia теперь возвращается null для производительности) */
  thumbnailWebPath: string | null;
  /** Ширина в пикселях */
  width: number;
  /** Высота в пикселях */
  height: number;
  /** Дата создания (ISO 8601 строка) */
  createdAt: string;
  /** Длительность в секундах (только для видео, 0 для фото) */
  duration: number;
  /** MIME-тип файла */
  mimeType: string;
  /** Размер файла в байтах */
  fileSize: number;
  /** Имя файла */
  fileName: string;
}

export interface GetMediaOptions {
  /** ID альбома. Если не передан — возвращает все медиафайлы. */
  albumId?: string;
  /** Максимальное количество элементов */
  limit: number;
  /** Сдвиг для пагинации */
  offset: number;
  /** Тип медиа: 'photo', 'video' или 'all' */
  type: MediaType;
}

export interface GetMediaResult {
  media: MediaItem[];
  /** Общее количество медиа, соответствующих фильтру (для пагинации) */
  total: number;
  /** Есть ли ещё элементы после текущей страницы */
  hasMore: boolean;
}

export interface GetThumbnailOptions {
  /** ID медиафайла */
  id: string;
}

export interface GetThumbnailResult {
  /** Base64 строка изображения (с префиксом data:image/jpeg;base64,...) */
  base64String: string;
}

// ─── Plugin Interface ────────────────────────────────────────────────────────

export interface CapacitorMediastorePlugin {
  /**
   * Проверяет текущий статус разрешений на доступ к медиагалерее.
   */
  checkPermissions(): Promise<PermissionResult>;

  /**
   * Запрашивает у пользователя разрешения на доступ к медиагалерее.
   */
  requestPermissions(): Promise<PermissionResult>;

  /**
   * Возвращает список альбомов на устройстве.
   */
  getAlbums(): Promise<GetAlbumsResult>;

  /**
   * Возвращает список медиафайлов с метаданными (БЕЗ миниатюр).
   */
  getMedia(options: GetMediaOptions): Promise<GetMediaResult>;

  /**
   * Генерирует миниатюру для указанного медиафайла (Lazy Load).
   */
  getThumbnail(options: GetThumbnailOptions): Promise<GetThumbnailResult>;
}
