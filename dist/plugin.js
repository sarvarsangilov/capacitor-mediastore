var capacitorCapacitorMediastore = (function (exports, core) {
    'use strict';

    const CapacitorMediastore = core.registerPlugin('CapacitorMediastore', {
        web: () => Promise.resolve().then(function () { return web; }).then((m) => new m.CapacitorMediastoreWeb()),
    });

    // ─────────────────────────────────────────────────────────────────────────────
    // Web (Mock) Implementation
    // ─────────────────────────────────────────────────────────────────────────────
    // Возвращает фейковые данные, чтобы можно было верстать UI в браузере
    // без реального устройства.
    // ─────────────────────────────────────────────────────────────────────────────
    /** Генерирует ISO-дату, сдвинутую на `daysAgo` дней назад */
    function fakeDate(daysAgo) {
        const d = new Date();
        d.setDate(d.getDate() - daysAgo);
        return d.toISOString();
    }
    /**
     * Набор фейковых альбомов для веб-среды.
     */
    const MOCK_ALBUMS = [
        {
            id: 'all',
            title: 'All Photos',
            count: 128,
            coverUri: 'https://picsum.photos/seed/cover_all/200/200',
            coverWebPath: 'https://picsum.photos/seed/cover_all/200/200',
            coverThumbnailWebPath: 'https://picsum.photos/seed/cover_all/200/200',
        },
        {
            id: 'camera',
            title: 'Camera',
            count: 85,
            coverUri: 'https://picsum.photos/seed/cover_camera/200/200',
            coverWebPath: 'https://picsum.photos/seed/cover_camera/200/200',
            coverThumbnailWebPath: 'https://picsum.photos/seed/cover_camera/200/200',
        },
        {
            id: 'screenshots',
            title: 'Screenshots',
            count: 23,
            coverUri: 'https://picsum.photos/seed/cover_screenshots/200/200',
            coverWebPath: 'https://picsum.photos/seed/cover_screenshots/200/200',
            coverThumbnailWebPath: 'https://picsum.photos/seed/cover_screenshots/200/200',
        },
        {
            id: 'downloads',
            title: 'Downloads',
            count: 12,
            coverUri: 'https://picsum.photos/seed/cover_downloads/200/200',
            coverWebPath: 'https://picsum.photos/seed/cover_downloads/200/200',
            coverThumbnailWebPath: 'https://picsum.photos/seed/cover_downloads/200/200',
        },
        {
            id: 'favorites',
            title: 'Favorites',
            count: 8,
            coverUri: 'https://picsum.photos/seed/cover_favorites/200/200',
            coverWebPath: 'https://picsum.photos/seed/cover_favorites/200/200',
            coverThumbnailWebPath: 'https://picsum.photos/seed/cover_favorites/200/200',
        },
    ];
    /**
     * Генерирует массив фейковых медиафайлов.
     */
    function generateMockMedia(count) {
        const items = [];
        for (let i = 0; i < count; i++) {
            const isVideo = i % 5 === 0; // каждый 5-й элемент — видео
            const imgUri = isVideo
                ? `https://picsum.photos/seed/vid${i}/1920/1080`
                : `https://picsum.photos/seed/img${i}/1080/1920`;
            items.push({
                id: `mock-media-${i}`,
                type: isVideo ? 'video' : 'photo',
                uri: imgUri,
                webPath: imgUri, // на вебе webPath === uri
                thumbnailUri: null, // Lazy load
                thumbnailWebPath: null, // Lazy load
                width: isVideo ? 1920 : 1080,
                height: isVideo ? 1080 : 1920,
                createdAt: fakeDate(i),
                duration: isVideo ? 15 + (i % 120) : 0,
                mimeType: isVideo ? 'video/mp4' : 'image/jpeg',
                fileSize: isVideo ? 15000000 + i * 100000 : 2000000 + i * 50000,
                fileName: isVideo ? `VID_${1000 + i}.mp4` : `IMG_${1000 + i}.jpg`,
            });
        }
        return items;
    }
    const MOCK_MEDIA = generateMockMedia(128);
    class CapacitorMediastoreWeb extends core.WebPlugin {
        // ── Permissions ──────────────────────────────────────────────────────────
        async checkPermissions() {
            // На вебе разрешения всегда «granted»
            return { photos: 'granted', videos: 'granted' };
        }
        async requestPermissions() {
            // На вебе разрешения всегда «granted»
            return { photos: 'granted', videos: 'granted' };
        }
        // ── Albums ───────────────────────────────────────────────────────────────
        async getAlbums() {
            return { albums: MOCK_ALBUMS };
        }
        // ── Media ────────────────────────────────────────────────────────────────
        async getMedia(options) {
            const { limit, offset, type } = options;
            // Фильтрация по типу
            let filtered;
            if (type === 'all') {
                filtered = MOCK_MEDIA;
            }
            else {
                filtered = MOCK_MEDIA.filter((m) => m.type === type);
            }
            const total = filtered.length;
            const sliced = filtered.slice(offset, offset + limit);
            const hasMore = offset + limit < total;
            return { media: sliced, total, hasMore };
        }
        // ── Lazy Thumbnails ──────────────────────────────────────────────────────
        async getThumbnail(options) {
            console.log(options);
            // Возвращаем серый квадрат 256x256 в base64
            const base64String = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAYAAABccqhmAAACZElEQVR42u3UMQEAMAjAsKF0BwLwf4EBHJBI6NH4Wf2Ak8IAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAMAADAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAwAAMAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAMwADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMAAxABjAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMADAAwAAAAwAMAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwAMADAAAADAAwADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADAAwAMAAAAMADADYDD91MR8IN1oiAAAAAElFTkSuQmCC';
            return { base64String };
        }
    }

    var web = /*#__PURE__*/Object.freeze({
        __proto__: null,
        CapacitorMediastoreWeb: CapacitorMediastoreWeb
    });

    exports.CapacitorMediastore = CapacitorMediastore;

    return exports;

})({}, capacitorExports);
//# sourceMappingURL=plugin.js.map
