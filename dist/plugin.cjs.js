'use strict';

var core = require('@capacitor/core');

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
    { id: 'all', title: 'All Photos', count: 128, coverUri: null },
    { id: 'camera', title: 'Camera', count: 85, coverUri: null },
    { id: 'screenshots', title: 'Screenshots', count: 23, coverUri: null },
    { id: 'downloads', title: 'Downloads', count: 12, coverUri: null },
    { id: 'favorites', title: 'Favorites', count: 8, coverUri: null },
];
/**
 * Генерирует массив фейковых медиафайлов.
 */
function generateMockMedia(count) {
    const items = [];
    for (let i = 0; i < count; i++) {
        const isVideo = i % 5 === 0; // каждый 5-й элемент — видео
        items.push({
            id: `mock-media-${i}`,
            type: isVideo ? 'video' : 'photo',
            uri: isVideo
                ? `https://picsum.photos/seed/vid${i}/1920/1080`
                : `https://picsum.photos/seed/img${i}/1080/1920`,
            thumbnailUri: `https://picsum.photos/seed/thumb${i}/200/200`,
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
}

var web = /*#__PURE__*/Object.freeze({
    __proto__: null,
    CapacitorMediastoreWeb: CapacitorMediastoreWeb
});

exports.CapacitorMediastore = CapacitorMediastore;
//# sourceMappingURL=plugin.cjs.js.map
