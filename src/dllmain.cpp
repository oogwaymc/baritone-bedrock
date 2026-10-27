#include <Windows.h>
#include <TlHelp32.h>
#include <winver.h>

#include <cstdint>
#include <cstring>
#include <format>
#include <iterator>
#include <string>
#include <string_view>
#include <vector>

#include "core/Bot.h"
#include "core/Chat.h"
#include "core/Log.h"
#include "core/Paths.h"
#include "core/Safe.h"
#include "core/Security.h"
#include "memory/Hooks.h"
#include "memory/Signatures.h"
#include "platform/WorldTracker.h"

#pragma comment(lib, "version.lib")  // GetFileVersionInfoW

// The game version the signatures and offsets were made for (sdk/Offsets.h)
#define BARITONE_SUPPORTED_GAME "26.52 (1.26.5203.0)"

namespace {

HMODULE g_module = nullptr;

// The game's version from Minecraft.Windows.exe's version resource ("1.26.5203.0"), empty if unknown.
std::string gameVersion() {
    wchar_t path[MAX_PATH * 2];
    DWORD len = GetModuleFileNameW(nullptr, path, static_cast<DWORD>(std::size(path)));
    if (!len || len >= std::size(path)) return {};
    DWORD ignored = 0;
    DWORD size = GetFileVersionInfoSizeW(path, &ignored);
    if (!size) return {};
    std::vector<uint8_t> data(size);
    if (!GetFileVersionInfoW(path, 0, size, data.data())) return {};
    VS_FIXEDFILEINFO* info = nullptr;
    UINT infoSize = 0;
    if (!VerQueryValueW(data.data(), L"\\", reinterpret_cast<void**>(&info), &infoSize) || !info ||
        infoSize < sizeof(VS_FIXEDFILEINFO)) {
        return {};
    }
    return std::format("{}.{}.{}.{}", HIWORD(info->dwFileVersionMS), LOWORD(info->dwFileVersionMS),
                       HIWORD(info->dwFileVersionLS), LOWORD(info->dwFileVersionLS));
}

// Named event so a dev tool can ask for an unload without typing in the game.
std::wstring unloadEventName() {
    return std::format(L"BaritoneBedrock_Unload_{}", GetCurrentProcessId());
}

// ---- another copy already in the game -------------------------------------------------------
// Injecting a new DLL while an older one (or the same one) is still loaded puts two bots on the
// same game functions, which can crash the game. Every version makes the unload event above, so
// a second copy sees it already exists: it then asks the first one to unload (as the dev tool
// does) and only starts once that one is gone.

// Any build of this project, whatever the DLL file was renamed to: the PDB path in its debug
// directory ends with \BaritoneBedrock.pdb.
bool isBaritoneBedrock(HMODULE module) {
    auto base = reinterpret_cast<const uint8_t*>(module);
    auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) return false;
    if (nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_DEBUG) return false;
    const IMAGE_DATA_DIRECTORY& dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DEBUG];
    if (!dir.VirtualAddress || dir.Size < sizeof(IMAGE_DEBUG_DIRECTORY)) return false;
    auto entries = reinterpret_cast<const IMAGE_DEBUG_DIRECTORY*>(base + dir.VirtualAddress);
    constexpr std::string_view kPdb = "\\BaritoneBedrock.pdb";
    for (std::size_t i = 0; i < dir.Size / sizeof(IMAGE_DEBUG_DIRECTORY); ++i) {
        const IMAGE_DEBUG_DIRECTORY& e = entries[i];
        // CodeView "RSDS" record: signature, GUID, age (24 bytes), then the PDB path
        if (e.Type != IMAGE_DEBUG_TYPE_CODEVIEW || !e.AddressOfRawData || e.SizeOfData <= 24) continue;
        auto cv = reinterpret_cast<const char*>(base + e.AddressOfRawData);
        if (std::memcmp(cv, "RSDS", 4) != 0) continue;
        std::string_view pdb(cv + 24, strnlen(cv + 24, e.SizeOfData - 24));
        if (pdb.size() >= kPdb.size() &&
            _strnicmp(pdb.data() + pdb.size() - kPdb.size(), kPdb.data(), kPdb.size()) == 0) {
            return true;
        }
    }
    return false;
}

// How many other copies of this DLL are loaded in the game, -1 if the modules can't be listed.
int otherCopies() {
    HANDLE snap = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 5 && snap == INVALID_HANDLE_VALUE; ++attempt) {
        snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
        if (snap == INVALID_HANDLE_VALUE) Sleep(20);  // ERROR_BAD_LENGTH while modules (un)load
    }
    if (snap == INVALID_HANDLE_VALUE) return -1;
    int count = 0;
    MODULEENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    for (BOOL ok = Module32FirstW(snap, &entry); ok; ok = Module32NextW(snap, &entry)) {
        if (entry.hModule == g_module) continue;
        // a reference while its headers are read, so the module can't be unmapped meanwhile
        HMODULE held = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, reinterpret_cast<LPCWSTR>(entry.modBaseAddr),
                                &held)) {
            continue;  // already unloaded
        }
        if (held != g_module && isBaritoneBedrock(held)) ++count;
        FreeLibrary(held);
    }
    CloseHandle(snap);
    return count;
}

// The unload event already existed: ask its owner to unload and wait until no other copy is
// loaded. Returns false if one is still there after the wait.
bool unloadOtherCopy(HANDLE unloadEvent) {
    SetEvent(unloadEvent);
    constexpr DWORD kStepMs = 100, kMinMs = 500, kMaxMs = 30000;  // its unload writes the cache
    bool gone = false;
    for (DWORD waited = 0; waited < kMaxMs && !gone; waited += kStepMs) {
        Sleep(kStepMs);
        // at least kMinMs: the other copy checks the event every 100 ms
        gone = waited + kStepMs >= kMinMs && otherCopies() == 0;
    }
    ResetEvent(unloadEvent);  // ours from now on
    return gone;
}

DWORD WINAPI mainThread(LPVOID) {
    OpenSecurity security;
    std::wstring eventName = unloadEventName();
    HANDLE unloadEvent = CreateEventW(security.get(), TRUE, FALSE, eventName.c_str());
    bool otherCopy = unloadEvent && GetLastError() == ERROR_ALREADY_EXISTS;  // right after: nothing may reset it
    bool otherGone = otherCopy && unloadOtherCopy(unloadEvent);

    // after the other copy is gone: it writes the same log.txt until it unloads
    logger::init(paths::dataDir() / "log.txt", true);
    logger::info("Baritone Bedrock {} - data dir: {}", BARITONE_BEDROCK_VERSION, paths::dataDir().string());

    if (otherCopy && !otherGone) {
        logger::error("Another Baritone Bedrock is loaded in this game and didn't unload: not starting. "
                      "Restart Minecraft and inject only one copy.");
        logger::shutdown();
        CloseHandle(unloadEvent);
        FreeLibraryAndExitThread(g_module, 0);
    }
    if (otherCopy) logger::info("Another Baritone Bedrock was already loaded in this game: it was unloaded first");

    std::string version = gameVersion();
    logger::info("Minecraft {} (this bot is made for {})", version.empty() ? "version unknown" : version, BARITONE_SUPPORTED_GAME);

    bool resolved = sigs::resolveAll();
    bool hooked = resolved && hooks::initialize();
    bool started = hooked && Bot::get().start();
    if (!started) {
        // Only undo what was done. With game functions missing, the full unload below reads game
        // memory through addresses that were never found, which crashed the game (26.60 update).
        logger::error("Initialisation failed, unloading. Is the game version supported?");
        if (hooked) safe::run("unload", [] { Bot::get().stop(); });
        hooks::shutdown();
        logger::info("Unloaded.");
        logger::shutdown();
        std::wstring text = std::format(
            L"Baritone Bedrock {} is made for Minecraft Bedrock {}, and this game is {}.\n\n"
            L"It couldn't find the game functions it needs, so it unloaded without changing anything. "
            L"Minecraft keeps running.\n\nIt needs an update for this version of Minecraft. Details in log.txt "
            L"(%LOCALAPPDATA%\\BaritoneBedrock).",
            L"" BARITONE_BEDROCK_VERSION, L"" BARITONE_SUPPORTED_GAME, version.empty() ? std::wstring(L"another version")
                                                                                : std::wstring(version.begin(), version.end()));
        MessageBoxW(nullptr, text.c_str(), L"Baritone Bedrock", MB_OK | MB_ICONWARNING | MB_SETFOREGROUND | MB_TOPMOST);
        if (unloadEvent) CloseHandle(unloadEvent);
        FreeLibraryAndExitThread(g_module, 0);
    }
    logger::info("Ready. Type #help in the chat.");
    if (otherCopy) chat::info("Replaced the Baritone Bedrock that was already loaded.");
    while (!Bot::get().unloadRequested() && WaitForSingleObject(unloadEvent, 100) == WAIT_TIMEOUT) {
    }

    logger::info("Unloading...");
    Bot::get().stop();
    hooks::shutdown();
    platform::WorldTracker::get().reset();  // writes the long-distance cache
    logger::info("Unloaded.");
    logger::shutdown();
    if (unloadEvent) CloseHandle(unloadEvent);
    FreeLibraryAndExitThread(g_module, 0);
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = module;
        DisableThreadLibraryCalls(module);
        if (HANDLE thread = CreateThread(nullptr, 0, mainThread, nullptr, 0, nullptr)) CloseHandle(thread);
    }
    return TRUE;
}
