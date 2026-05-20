import { WebPlugin } from '@capacitor/core';
import type { CapacitorMediastorePlugin, PermissionResult, GetAlbumsResult, GetMediaOptions, GetMediaResult, GetThumbnailOptions, GetThumbnailResult, GetThumbnailsOptions, GetThumbnailsResult, PickFilesOptions, PickFilesResult, GetRecentFilesOptions, GetRecentFilesResult, RemoveRecentFileOptions, ResolveRecentFileOptions, ResolveRecentFileResult } from './definitions';
export declare class CapacitorMediastoreWeb extends WebPlugin implements CapacitorMediastorePlugin {
    checkPermissions(): Promise<PermissionResult>;
    requestPermissions(): Promise<PermissionResult>;
    getAlbums(): Promise<GetAlbumsResult>;
    getMedia(options: GetMediaOptions): Promise<GetMediaResult>;
    getThumbnail(options: GetThumbnailOptions): Promise<GetThumbnailResult>;
    getThumbnails(options: GetThumbnailsOptions): Promise<GetThumbnailsResult>;
    pickFiles(options?: PickFilesOptions): Promise<PickFilesResult>;
    getRecentFiles(options?: GetRecentFilesOptions): Promise<GetRecentFilesResult>;
    resolveRecentFile(options: ResolveRecentFileOptions): Promise<ResolveRecentFileResult>;
    removeRecentFile(options: RemoveRecentFileOptions): Promise<void>;
    clearRecentFiles(): Promise<void>;
}
