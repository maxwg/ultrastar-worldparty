/* Inert Windows-only process/media fixture. No network, shell, or user data. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define PATH_CAP 32768
#define HOLD_MS 630000

static wchar_t self_path[PATH_CAP];
static wchar_t self_dir[PATH_CAP];

static int local_path(wchar_t *out, size_t count, const wchar_t *name) {
    return swprintf_s(out, count, L"%ls\\%ls", self_dir, name) >= 0;
}

static int write_bytes(const wchar_t *path, const void *bytes, DWORD size) {
    HANDLE file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD written = 0;
    int ok;
    if (file == INVALID_HANDLE_VALUE) return 0;
    ok = WriteFile(file, bytes, size, &written, NULL) && written == size;
    CloseHandle(file);
    return ok;
}

static int record_pid(const wchar_t *name) {
    wchar_t path[PATH_CAP];
    char pid[32];
    int size = sprintf_s(pid, sizeof(pid), "%lu\n", GetCurrentProcessId());
    if (size <= 0 || !local_path(path, PATH_CAP, name)) return 0;
    return write_bytes(path, pid, (DWORD)size);
}

static int read_mode(char *mode, size_t count) {
    wchar_t path[PATH_CAP];
    FILE *file = NULL;
    size_t size;
    if (!local_path(path, PATH_CAP, L"mode.txt") ||
        _wfopen_s(&file, path, L"rb") != 0 || !file) return 0;
    size = fread(mode, 1, count - 1, file);
    fclose(file);
    mode[size] = '\0';
    while (size && (mode[size-1] == '\r' || mode[size-1] == '\n' ||
                    mode[size-1] == ' ' || mode[size-1] == '\t')) {
        mode[--size] = '\0';
    }
    return 1;
}

static int record_argv(int argc, wchar_t **argv) {
    wchar_t path[PATH_CAP];
    FILE *file = NULL;
    uint32_t value = (uint32_t)argc;
    int i, ok = 1;
    if (!local_path(path, PATH_CAP, L"argv.bin") ||
        _wfopen_s(&file, path, L"wb") != 0 || !file) return 0;
    if (fwrite(&value, sizeof(value), 1, file) != 1) ok = 0;
    for (i = 0; ok && i < argc; ++i) {
        int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                        argv[i], -1, NULL, 0, NULL, NULL);
        char *utf8;
        if (length <= 0) { ok = 0; break; }
        utf8 = (char *)malloc((size_t)length);
        if (!utf8) { ok = 0; break; }
        if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1,
                                 utf8, length, NULL, NULL)) {
            free(utf8); ok = 0; break;
        }
        value = (uint32_t)(length - 1);
        ok = fwrite(&value, sizeof(value), 1, file) == 1 &&
             fwrite(utf8, 1, value, file) == value;
        free(utf8);
    }
    if (fclose(file) != 0) ok = 0;
    return ok;
}

static int spawn_role(const wchar_t *role) {
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    wchar_t command[PATH_CAP + 128];
    BOOL ok;
    if (swprintf_s(command, PATH_CAP + 128, L"\"%ls\" %ls", self_path, role) < 0)
        return 0;
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    ok = CreateProcessW(self_path, command, NULL, NULL, TRUE, CREATE_NO_WINDOW,
                        NULL, self_dir, &startup, &process);
    if (!ok) return 0;
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 1;
}

static void wait_marker(const wchar_t *name, DWORD timeout_ms) {
    wchar_t path[PATH_CAP];
    ULONGLONG start = GetTickCount64();
    if (!local_path(path, PATH_CAP, name)) return;
    while (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES &&
           GetTickCount64() - start < timeout_ms) Sleep(20);
}

static int write_media(const wchar_t *path) {
    char data[64];
    if (!path) return 0;
    memset(data, 'F', sizeof(data));
    return write_bytes(path, data, sizeof(data));
}

int wmain(int argc, wchar_t **argv) {
    DWORD length = GetModuleFileNameW(NULL, self_path, PATH_CAP);
    wchar_t *basename;
    const wchar_t *output = NULL;
    char mode[128] = "success";
    int i;
    if (!length || length >= PATH_CAP) return 80;
    if (wcscpy_s(self_dir, PATH_CAP, self_path) != 0) return 81;
    basename = wcsrchr(self_dir, L'\\');
    if (!basename) return 82;
    *basename = L'\0';
    basename = wcsrchr(self_path, L'\\');
    if (!basename) return 83;
    ++basename;

    if (argc == 2 && wcscmp(argv[1], L"--fixture-child") == 0) {
        if (!record_pid(L"child.pid")) return 84;
        if (!spawn_role(L"--fixture-grandchild")) return 85;
        Sleep(HOLD_MS); return 0;
    }
    if (argc == 2 && wcscmp(argv[1], L"--fixture-grandchild") == 0) {
        if (!record_pid(L"grandchild.pid")) return 86;
        Sleep(HOLD_MS); return 0;
    }
    if (argc == 2 && wcscmp(argv[1], L"--fixture-probe-child") == 0) {
        if (!record_pid(L"probe_child.pid")) return 87;
        Sleep(HOLD_MS); return 0;
    }

    read_mode(mode, sizeof(mode));
    if (_wcsicmp(basename, L"ffprobe.exe") == 0) {
        if (!record_pid(L"probe.pid")) return 88;
        if (strcmp(mode, "probe_hold") == 0) wait_marker(L"release_probe", 10000);
        if (strcmp(mode, "probe_fail") == 0) return 9;
        if (strcmp(mode, "probe_descendant") == 0 &&
            !spawn_role(L"--fixture-probe-child")) return 89;
        if (strcmp(mode, "probe_noaudio") == 0)
            fputs("{\"streams\":[{\"codec_type\":\"video\"}]}\n", stdout);
        else if (strcmp(mode, "probe_badjson") == 0)
            fputs("FIXTURE INVALID JSON\n", stdout);
        else
            fputs("{\"streams\":[{\"codec_type\":\"audio\"}]}\n", stdout);
        fflush(stdout);
        return 0;
    }

    if (!record_pid(L"parent.pid") || !record_argv(argc, argv)) return 90;
    for (i = 1; i + 1 < argc; ++i)
        if (wcscmp(argv[i], L"-o") == 0) output = argv[++i];
    fputs("FIXTURE DOWNLOADER STDOUT NOISE\n", stdout);
    fputs("FIXTURE DOWNLOADER STDERR NOISE\n", stderr);
    fflush(stdout); fflush(stderr);
    if (strcmp(mode, "hold") == 0 || strcmp(mode, "exit_descendants") == 0 ||
        strcmp(mode, "nonzero_descendants") == 0) {
        if (!spawn_role(L"--fixture-child")) return 91;
        if (strcmp(mode, "hold") == 0) { Sleep(HOLD_MS); return 0; }
        wait_marker(L"release", 15000);
    }
    if (strcmp(mode, "missing") == 0) return 0;
    if (!write_media(output)) return 92;
    if (strcmp(mode, "nonzero") == 0 || strcmp(mode, "nonzero_descendants") == 0)
        return 7;
    return 0;
}
