import { WebPlugin } from '@capacitor/core';
import type { CapacitorMediastorePlugin, PermissionResult, GetAlbumsResult, GetMediaOptions, GetMediaResult, GetThumbnailOptions, GetThumbnailResult, GetThumbnailsOptions, GetThumbnailsResult, PickFilesOptions, PickFilesResult, GetRecentFilesOptions, GetRecentFilesResult, RemoveRecentFileOptions, ResolveRecentFileOptions, ResolveRecentFileResult, HasMediaOptions, HasMediaResult, ResolveMediaPathOptions, ResolveMediaPathResult, ReadFileChunkOptions, ReadFileChunkResult } from './definitions';
export declare class CapacitorMediastoreWeb extends WebPlugin implements CapacitorMediastorePlugin {
    checkPermissions(): Promise<PermissionResult>;
    requestPermissions(): Promise<PermissionResult>;
    getAlbums(): Promise<GetAlbumsResult>;
    getMedia(options: GetMediaOptions): Promise<GetMediaResult>;
    hasMedia(options: HasMediaOptions): Promise<HasMediaResult>;
    resolveMediaPath(options: ResolveMediaPathOptions): Promise<ResolveMediaPathResult>;
    getThumbnail(options: GetThumbnailOptions): Promise<GetThumbnailResult>;
    getThumbnails(options: GetThumbnailsOptions): Promise<GetThumbnailsResult>;
    prefetchThumbnails(_options: GetThumbnailsOptions): Promise<void>;
    cancelPendingThumbnails(): Promise<void>;
    pickFiles(options?: PickFilesOptions): Promise<PickFilesResult>;
    getRecentFiles(options?: GetRecentFilesOptions): Promise<GetRecentFilesResult>;
    resolveRecentFile(options: ResolveRecentFileOptions): Promise<ResolveRecentFileResult>;
    readFileChunk(options: ReadFileChunkOptions): Promise<ReadFileChunkResult>;
    removeRecentFile(options: RemoveRecentFileOptions): Promise<void>;
    clearRecentFiles(): Promise<void>;
}
