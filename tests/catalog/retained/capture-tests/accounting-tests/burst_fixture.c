/* Inert local fixture:32 immediately-exiting descendants, no network or inputs. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>

static int marker(const wchar_t *name, DWORD timeout) {
    ULONGLONG end = GetTickCount64() + timeout;
    while (GetFileAttributesW(name) == INVALID_FILE_ATTRIBUTES) {
        if (GetTickCount64() >= end) return 0;
        Sleep(2);
    }
    return 1;
}

int wmain(int argc, wchar_t **argv) {
    wchar_t exe[32768], command[32768 + 32];
    HANDLE children[32] = {0};
    DWORD pids[32] = {0};
    FILE *file = NULL;
    int i;
    if (argc == 2 && wcscmp(argv[1], L"--child") == 0) return 0;
    if (!GetModuleFileNameW(NULL, exe, 32768)) return 10;
    if (_wfopen_s(&file, L"root.pid", L"wb") || !file) return 11;
    fprintf(file, "%lu", GetCurrentProcessId()); fclose(file);
    if (!marker(L"start", 10000)) return 12;
    for (i = 0; i < 32; ++i) {
        STARTUPINFOW startup = {0};
        PROCESS_INFORMATION process = {0};
        startup.cb = sizeof(startup);
        if (swprintf_s(command, 32768 + 32, L"\"%ls\" --child", exe) < 0) return 13;
        if (!CreateProcessW(exe, command, NULL, NULL, FALSE, CREATE_NO_WINDOW,
                            NULL, NULL, &startup, &process)) return 14;
        CloseHandle(process.hThread);
        children[i] = process.hProcess;
        pids[i] = process.dwProcessId;
        if (WaitForSingleObject(process.hProcess, 1000) != WAIT_OBJECT_0) return 15;
    }
    if (_wfopen_s(&file, L"burst.tmp", L"wb") || !file) return 16;
    fputs("[", file);
    for (i = 0; i < 32; ++i)
        fprintf(file, "%s{\"pid\":%lu,\"handle\":%llu}", i ? "," : "", pids[i],
                (unsigned long long)(uintptr_t)children[i]);
    fputs("]", file); fclose(file);
    if (!MoveFileW(L"burst.tmp", L"burst.json")) return 17;
    if (!marker(L"release", 10000)) return 18;
    for (i = 0; i < 32; ++i) CloseHandle(children[i]);
    return 0;
}
