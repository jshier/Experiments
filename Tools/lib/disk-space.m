// disk-space: a volume's free space three ways, in bytes, tab-separated (Tools/disk-space):
//   path         the path measured (see below)
//   total        the volume's size
//   free         blocks free now (statfs; what `df` shows: writes and the kernel see this)
//   important    available for important use: free plus purgeable space the system frees on demand (what Finder shows)
//   opportunistic available for opportunistic use: what background work may take without the system purging
//   read-only    "yes" or "no" (the mount's MNT_RDONLY flag)
// PATH defaults to the Data volume. A PATH that doesn't exist yet is measured at its nearest existing ancestor (a
// dangling symbolic link at its target's), unless the first missing component is right under /Volumes: a volume that
// isn't mounted (/Volumes in any spelling, by device and inode), refused (exit 3). `/` itself, asked for and existing, in
// any spelling (`/.`, `//`, `/System/..`, `/Volumes/Macintosh HD`:
// whatever realpath makes `/`), is measured as the Data volume; any other path on the sealed system volume is reported
// as what it is, read-only. Notes on stderr say which.
#import <Foundation/Foundation.h>
#include <errno.h>
#include <limits.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>

static const char *const dataVolume = "/System/Volumes/Data";

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        char path[PATH_MAX], resolved[PATH_MAX];
        struct statfs fs, root;
        int missing = 0, hops = 0;
        strlcpy(path, argc > 1 ? argv[1] : (statfs(dataVolume, &fs) == 0 ? dataVolume : "/"), sizeof path);
        // The nearest existing ancestor of a path that doesn't exist yet. A dangling symbolic link is followed to its
        // target (whose volume is the one a write would reach).
        while (statfs(path, &fs) != 0) {
            if (errno != ENOENT && errno != ENOTDIR) { perror(path); return 1; }
            char target[PATH_MAX];
            ssize_t length = readlink(path, target, sizeof target - 1);
            if (length > 0 && hops++ < 16) {
                target[length] = '\0';
                if (target[0] == '/') {
                    strlcpy(path, target, sizeof path);
                } else {
                    char *slash = strrchr(path, '/');
                    if (slash) slash[1] = '\0'; else path[0] = '\0';
                    strlcat(path, target, sizeof path);
                }
                continue;
            }
            missing = 1;
            size_t end = strlen(path);
            while (end > 1 && path[end - 1] == '/') path[--end] = '\0';
            char *slash = strrchr(path, '/');
            if (slash == NULL) { strlcpy(path, ".", sizeof path); continue; }
            if (slash == path) { path[1] = '\0'; } else { *slash = '\0'; }
        }
        if (realpath(path, resolved) == NULL) strlcpy(resolved, path, sizeof resolved);
        // A missing component right under /Volumes is a volume that isn't mounted: nothing there can be written.
        // Compared by device and inode, so /System/Volumes/Data/Volumes (the same directory) counts too.
        struct stat ancestor, volumes;
        if (missing && stat(path, &ancestor) == 0 && stat("/Volumes", &volumes) == 0 && ancestor.st_dev == volumes.st_dev &&
            ancestor.st_ino == volumes.st_ino) {
            fprintf(stderr, "%s is on a volume under /Volumes that isn't mounted\n", argc > 1 ? argv[1] : path);
            return 3;
        }
        if (missing)
            fprintf(stderr, "%s doesn't exist yet: measuring its nearest existing ancestor, %s\n", argv[1], path);
        // `/` itself (in any spelling: /., //, /System/.., /Volumes/Macintosh HD) is read as the Data volume: the sealed
        // system volume's figures are the container's, and its writable twin is the Data volume. Any other path on
        // the system volume is reported as it is: read-only.
        // Only when / itself was asked for: a new path at the top of the system volume (`/Scratch/x`, a typo) can't be
        // written, and stays on the system volume, read-only.
        if (!missing && strcmp(resolved, "/") == 0 && statfs("/", &root) == 0 && (root.f_flags & MNT_RDONLY) &&
            statfs(dataVolume, &fs) == 0) {
            fprintf(stderr, "%s is the read-only system volume: measuring the Data volume, %s\n", path, dataVolume);
            strlcpy(path, dataVolume, sizeof path);
        }
        unsigned long long freeBytes = (unsigned long long)fs.f_bavail * fs.f_bsize;
        unsigned long long totalBytes = (unsigned long long)fs.f_blocks * fs.f_bsize;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        NSError *error = nil;
        NSDictionary *values = [url resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey,
                                                           NSURLVolumeAvailableCapacityForOpportunisticUsageKey]
                                                    error:&error];
        if (values == nil) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        // Only APFS has purgeable space to count. On other volumes (exFAT, MS-DOS, HFS+ images) Foundation reports both
        // figures as 0, not as missing: what's free is what's available there. Likewise for a figure that's absent.
        BOOL apfs = strcmp(fs.f_fstypename, "apfs") == 0;
        NSNumber *importantValue = values[NSURLVolumeAvailableCapacityForImportantUsageKey];
        NSNumber *opportunisticValue = values[NSURLVolumeAvailableCapacityForOpportunisticUsageKey];
        long long important = apfs && importantValue.longLongValue > 0 ? importantValue.longLongValue : (long long)freeBytes;
        long long opportunistic =
            apfs && opportunisticValue.longLongValue > 0 ? opportunisticValue.longLongValue : (long long)freeBytes;
        printf("%s\t%llu\t%llu\t%lld\t%lld\t%s\n", path, totalBytes, freeBytes, important, opportunistic,
               (fs.f_flags & MNT_RDONLY) ? "yes" : "no");
    }
    return 0;
}
