var capacitorCapacitorMediastore = (function (exports, core) {
    'use strict';

    const CapacitorMediastore = core.registerPlugin('CapacitorMediastore', {
        web: () => Promise.resolve().then(function () { return web; }).then((m) => new m.CapacitorMediastoreWeb()),
    });

    // ─────────────────────────────────────────────────────────────────────────────
    // Web (Mock) Implementation
    // ─────────────────────────────────────────────────────────────────────────────
    // Возвращает фейковые данные, чтобы можно было верстать UI в браузере
    // без реального устройства. Файлпикер реализован поверх `<input type="file">`.
    // «Недавние» хранятся в `window.localStorage` и переживают перезагрузку страницы.
    // ─────────────────────────────────────────────────────────────────────────────
    const STORE_KEY = 'capacitor-mediastore-web-recent';
    /** Генерирует ISO-дату, сдвинутую на `daysAgo` дней назад. */
    function fakeDate(daysAgo) {
        const d = new Date();
        d.setDate(d.getDate() - daysAgo);
        return d.toISOString();
    }
    const MOCK_BASE64 = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    function mockThumbWebPath(id, size = 256) {
        return `https://picsum.photos/seed/${encodeURIComponent(id)}/${size}/${size}`;
    }
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
    ];
    function generateMockMedia(count) {
        const items = [];
        for (let i = 0; i < count; i++) {
            const isVideo = i % 5 === 0;
            const imgUri = isVideo
                ? `https://picsum.photos/seed/vid${i}/1920/1080`
                : `https://picsum.photos/seed/img${i}/1080/1920`;
            items.push({
                id: `mock-media-${i}`,
                type: isVideo ? 'video' : 'photo',
                uri: imgUri,
                webPath: imgUri,
                thumbnailUri: null,
                thumbnailWebPath: null,
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
    function generateMockAudio(count) {
        const artists = ['Daft Punk', 'Radiohead', 'Aphex Twin', 'Boards of Canada', 'Air'];
        const items = [];
        for (let i = 0; i < count; i++) {
            items.push({
                id: `mock-audio-${i}`,
                type: 'audio',
                uri: `https://example.com/audio/${i}.mp3`,
                webPath: `https://example.com/audio/${i}.mp3`,
                thumbnailUri: null,
                thumbnailWebPath: null,
                width: 0,
                height: 0,
                createdAt: fakeDate(i),
                duration: 120 + (i % 240),
                mimeType: 'audio/mpeg',
                fileSize: 5000000 + i * 100000,
                fileName: `Track ${i + 1}.mp3`,
                title: `Track ${i + 1}`,
                artist: artists[i % artists.length],
                album: `Album ${Math.floor(i / 5) + 1}`,
            });
        }
        return items;
    }
    const MOCK_MEDIA = generateMockMedia(128);
    const MOCK_AUDIO = generateMockAudio(40);
    function readRecentStore() {
        if (typeof window === 'undefined' || !window.localStorage)
            return [];
        try {
            const raw = window.localStorage.getItem(STORE_KEY);
            return raw ? JSON.parse(raw) : [];
        }
        catch (_a) {
            return [];
        }
    }
    function writeRecentStore(items) {
        if (typeof window === 'undefined' || !window.localStorage)
            return;
        try {
            window.localStorage.setItem(STORE_KEY, JSON.stringify(items));
        }
        catch (_a) {
            /* ignore quota errors */
        }
    }
    function matchesMime(mime, pattern) {
        if (pattern === '*/*')
            return true;
        if (pattern.endsWith('/*')) {
            const prefix = pattern.slice(0, -2);
            return mime.toLowerCase().startsWith(`${prefix}/`);
        }
        return mime.toLowerCase() === pattern.toLowerCase();
    }
    class CapacitorMediastoreWeb extends core.WebPlugin {
        // ── Permissions ──────────────────────────────────────────────────────────
        async checkPermissions() {
            return { photos: 'granted', videos: 'granted', audio: 'granted' };
        }
        async requestPermissions() {
            return { photos: 'granted', videos: 'granted', audio: 'granted' };
        }
        // ── Albums ───────────────────────────────────────────────────────────────
        async getAlbums() {
            return { albums: MOCK_ALBUMS };
        }
        // ── Media ────────────────────────────────────────────────────────────────
        async getMedia(options) {
            const { limit, offset, type } = options;
            let filtered;
            if (type === 'audio') {
                filtered = MOCK_AUDIO;
            }
            else if (type === 'all') {
                filtered = MOCK_MEDIA; // photo + video, без audio (как на нативных платформах)
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
            var _a;
            const size = (_a = options.size) !== null && _a !== void 0 ? _a : 256;
            const webPath = mockThumbWebPath(options.id, size);
            const base64String = options.returnBase64 ? MOCK_BASE64 : '';
            return { webPath, base64String };
        }
        async getThumbnails(options) {
            var _a;
            const size = (_a = options.size) !== null && _a !== void 0 ? _a : 256;
            const thumbnails = {};
            for (const id of options.ids) {
                thumbnails[id] = mockThumbWebPath(id, size);
            }
            return { thumbnails };
        }
        // ── File picker / Recent files ───────────────────────────────────────────
        async pickFiles(options) {
            if (typeof document === 'undefined')
                return { files: [] };
            return new Promise((resolve) => {
                const input = document.createElement('input');
                input.type = 'file';
                input.style.display = 'none';
                if (options === null || options === void 0 ? void 0 : options.multiple)
                    input.multiple = true;
                if ((options === null || options === void 0 ? void 0 : options.mimeTypes) && options.mimeTypes.length > 0) {
                    input.accept = options.mimeTypes.join(',');
                }
                input.onchange = () => {
                    const files = input.files ? Array.from(input.files) : [];
                    const now = new Date().toISOString();
                    const store = readRecentStore();
                    const picked = files.map((file) => {
                        const url = URL.createObjectURL(file);
                        const id = `web-${now}-${file.name}`;
                        return {
                            id,
                            uri: url,
                            webPath: url,
                            fileName: file.name,
                            mimeType: file.type || 'application/octet-stream',
                            fileSize: file.size,
                            pickedAt: now,
                            lastAccessedAt: now,
                        };
                    });
                    // Удаляем дубли по fileName + size и кладём новые в начало.
                    const filteredStore = store.filter((s) => !picked.some((p) => p.fileName === s.fileName && p.fileSize === s.fileSize));
                    writeRecentStore([...picked, ...filteredStore]);
                    document.body.removeChild(input);
                    resolve({ files: picked });
                };
                // На случай отмены — нет надёжного события, поэтому в браузерной mock-версии
                // отмена не отдаётся в плагин. На нативных платформах это работает корректно.
                document.body.appendChild(input);
                input.click();
            });
        }
        async getRecentFiles(options) {
            var _a, _b, _c;
            const limit = (_a = options === null || options === void 0 ? void 0 : options.limit) !== null && _a !== void 0 ? _a : 50;
            const offset = (_b = options === null || options === void 0 ? void 0 : options.offset) !== null && _b !== void 0 ? _b : 0;
            const mimes = (_c = options === null || options === void 0 ? void 0 : options.mimeTypes) !== null && _c !== void 0 ? _c : [];
            const all = readRecentStore();
            const filtered = mimes.length === 0 ? all : all.filter((f) => mimes.some((p) => matchesMime(f.mimeType, p)));
            const sorted = [...filtered].sort((a, b) => (a.lastAccessedAt < b.lastAccessedAt ? 1 : -1));
            const total = sorted.length;
            const page = sorted.slice(offset, offset + limit);
            return { files: page, total, hasMore: offset + limit < total };
        }
        async resolveRecentFile(options) {
            const all = readRecentStore();
            const idx = all.findIndex((f) => f.id === options.id);
            if (idx < 0)
                return { file: null };
            const updated = Object.assign(Object.assign({}, all[idx]), { lastAccessedAt: new Date().toISOString() });
            all[idx] = updated;
            writeRecentStore(all);
            return { file: updated };
        }
        async removeRecentFile(options) {
            const all = readRecentStore();
            writeRecentStore(all.filter((f) => f.id !== options.id));
        }
        async clearRecentFiles() {
            writeRecentStore([]);
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
