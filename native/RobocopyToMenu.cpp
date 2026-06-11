// RobocopyToMenu.cpp - IExplorerCommand shell extension for RobocopyTo.
//
// Provides the "Robocopy" flyout (Copy to / Mirror to / Move to / Robopaste /
// Undo / Settings) with live state: Robopaste greys out when the clipboard
// holds no files, Mirror hides for file selections, Undo greys out when the
// journal has nothing left to undo. Text-only entries by design (no icons).
// Works in the classic context menu via per-user "ExplorerCommandHandler" verb
// registration (no admin), and in the Windows 11 top-level menu when packaged
// as a sparse MSIX.
//
// Raw COM on purpose: no ATL/WRL/CRT-heavy dependencies; the DLL stays tiny
// and loads nothing into Explorer beyond what it needs. All real work happens
// in a separate launcher process; Invoke() only builds a command line.
//
// Build: native\build.ps1 (cl /LD, see that script for flags).

#include <windows.h>
#include <shlwapi.h>
#include <shobjidl_core.h>
#include <strsafe.h>
#include <new>

#pragma comment(lib, "shlwapi.lib")

// {6F1A3B58-2D94-4E1C-9C7A-8B5E0D4F2A17}
static const CLSID CLSID_RobocopyToMenu =
{ 0x6f1a3b58, 0x2d94, 0x4e1c, { 0x9c, 0x7a, 0x8b, 0x5e, 0x0d, 0x4f, 0x2a, 0x17 } };

static HMODULE g_module = nullptr;
static volatile LONG g_refs = 0;

static void DllAddRef() { InterlockedIncrement(&g_refs); }
static void DllRelease() { InterlockedDecrement(&g_refs); }

enum class Cmd { CopyTo = 0, MirrorTo, MoveTo, Robopaste, Undo, Settings, Count };

static const wchar_t* CmdTitle(Cmd c) {
    switch (c) {
    case Cmd::CopyTo:    return L"Copy to\x2026";
    case Cmd::MirrorTo:  return L"Mirror to\x2026";
    case Cmd::MoveTo:    return L"Move to\x2026";
    case Cmd::Robopaste: return L"Robopaste";
    case Cmd::Undo:      return L"Undo";
    case Cmd::Settings:  return L"RobocopyTo settings";
    default:             return L"";
    }
}

static const wchar_t* CmdVerb(Cmd c) {
    switch (c) {
    case Cmd::CopyTo:    return L"copyto";
    case Cmd::MirrorTo:  return L"mirrorto";
    case Cmd::MoveTo:    return L"moveto";
    case Cmd::Robopaste: return L"paste";
    case Cmd::Undo:      return L"undo";
    case Cmd::Settings:  return L"settings";
    default:             return L"";
    }
}

static const wchar_t* CmdCanonical(Cmd c) {
    switch (c) {
    case Cmd::CopyTo:    return L"RobocopyTo.CopyTo";
    case Cmd::MirrorTo:  return L"RobocopyTo.MirrorTo";
    case Cmd::MoveTo:    return L"RobocopyTo.MoveTo";
    case Cmd::Robopaste: return L"RobocopyTo.Paste";
    case Cmd::Undo:      return L"RobocopyTo.Undo";
    case Cmd::Settings:  return L"RobocopyTo.Settings";
    default:             return L"RobocopyTo";
    }
}

// Per-user install metadata (InstallDir, last-op marker). The menu is text-only
// by design - no icon values are read or provided.
static HRESULT ReadInstallString(const wchar_t* name, wchar_t* buf, DWORD cch) {
    DWORD size = cch * sizeof(wchar_t);
    LSTATUS s = RegGetValueW(HKEY_CURRENT_USER, L"Software\\RobocopyTo", name,
                             RRF_RT_REG_SZ, nullptr, buf, &size);
    return (s == ERROR_SUCCESS) ? S_OK : E_FAIL;
}

// True when the journal holds an operation the launcher can undo right now.
// The PowerShell side refreshes these values after every operation and undo.
static bool HasUndoableOp() {
    wchar_t buf[64];
    return SUCCEEDED(ReadInstallString(L"LastUndoableOp", buf, ARRAYSIZE(buf))) && buf[0] != L'\0';
}

// Builds: "<InstallDir>\RobocopyTo.exe" --verb <verb> (--path "<p>" | --pathfile "<f>")
static HRESULT GetLauncherPath(wchar_t* buf, DWORD cch) {
    wchar_t dir[MAX_PATH];
    if (SUCCEEDED(ReadInstallString(L"InstallDir", dir, ARRAYSIZE(dir)))) {
        StringCchPrintfW(buf, cch, L"%s\\RobocopyTo.exe", dir);
        if (PathFileExistsW(buf)) return S_OK;
    }
    // fallback: next to this DLL
    wchar_t self[MAX_PATH];
    if (GetModuleFileNameW(g_module, self, ARRAYSIZE(self)) == 0) return E_FAIL;
    PathRemoveFileSpecW(self);
    StringCchPrintfW(buf, cch, L"%s\\RobocopyTo.exe", self);
    return PathFileExistsW(buf) ? S_OK : E_FAIL;
}

static bool ClipboardHasFiles() {
    return IsClipboardFormatAvailable(CF_HDROP) != FALSE;
}

// Writes selected paths to a temp file (UTF-8 BOM, one per line). Caller owns no cleanup;
// the launcher deletes the file after reading it.
static HRESULT WriteSelectionFile(IShellItemArray* items, wchar_t* outPath, DWORD cch) {
    DWORD count = 0;
    HRESULT hr = items->GetCount(&count);
    if (FAILED(hr) || count == 0) return E_FAIL;

    wchar_t tempDir[MAX_PATH];
    if (GetTempPathW(ARRAYSIZE(tempDir), tempDir) == 0) return E_FAIL;
    wchar_t tempFile[MAX_PATH];
    StringCchPrintfW(tempFile, ARRAYSIZE(tempFile), L"%srt-sel-%08x%08x.txt",
                     tempDir, GetCurrentProcessId(), GetTickCount());

    HANDLE h = CreateFileW(tempFile, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_TEMPORARY, nullptr);
    if (h == INVALID_HANDLE_VALUE) return E_FAIL;

    const unsigned char bom[3] = { 0xEF, 0xBB, 0xBF };
    DWORD written = 0;
    WriteFile(h, bom, 3, &written, nullptr);

    bool any = false;
    for (DWORD i = 0; i < count; i++) {
        IShellItem* item = nullptr;
        if (FAILED(items->GetItemAt(i, &item))) continue;
        PWSTR path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
            int len = WideCharToMultiByte(CP_UTF8, 0, path, -1, nullptr, 0, nullptr, nullptr);
            if (len > 1) {
                char* utf8 = (char*)LocalAlloc(LMEM_FIXED, len + 2);
                if (utf8) {
                    WideCharToMultiByte(CP_UTF8, 0, path, -1, utf8, len, nullptr, nullptr);
                    WriteFile(h, utf8, len - 1, &written, nullptr);
                    WriteFile(h, "\r\n", 2, &written, nullptr);
                    LocalFree(utf8);
                    any = true;
                }
            }
            CoTaskMemFree(path);
        }
        item->Release();
    }
    CloseHandle(h);
    if (!any) { DeleteFileW(tempFile); return E_FAIL; }
    StringCchCopyW(outPath, cch, tempFile);
    return S_OK;
}

static HRESULT LaunchVerb(Cmd cmd, IShellItemArray* items, IShellItem* folderFallback) {
    wchar_t exe[MAX_PATH];
    HRESULT hr = GetLauncherPath(exe, ARRAYSIZE(exe));
    if (FAILED(hr)) return hr;

    wchar_t args[2048];
    StringCchPrintfW(args, ARRAYSIZE(args), L"\"%s\" --verb %s", exe, CmdVerb(cmd));

    // settings and undo act on stored state, not on the selection
    if (cmd != Cmd::Settings && cmd != Cmd::Undo) {
        DWORD count = 0;
        if (items) items->GetCount(&count);
        if (cmd == Cmd::Robopaste) {
            // destination folder: the clicked folder, or the browsed folder on background clicks
            PWSTR path = nullptr;
            if (count >= 1) {
                IShellItem* item = nullptr;
                if (SUCCEEDED(items->GetItemAt(0, &item))) {
                    item->GetDisplayName(SIGDN_FILESYSPATH, &path);
                    item->Release();
                }
            } else if (folderFallback) {
                folderFallback->GetDisplayName(SIGDN_FILESYSPATH, &path);
            }
            if (!path) return E_FAIL;
            StringCchCatW(args, ARRAYSIZE(args), L" --path \"");
            StringCchCatW(args, ARRAYSIZE(args), path);
            StringCchCatW(args, ARRAYSIZE(args), L"\"");
            CoTaskMemFree(path);
        } else if (count > 1) {
            wchar_t listFile[MAX_PATH];
            hr = WriteSelectionFile(items, listFile, ARRAYSIZE(listFile));
            if (FAILED(hr)) return hr;
            StringCchCatW(args, ARRAYSIZE(args), L" --pathfile \"");
            StringCchCatW(args, ARRAYSIZE(args), listFile);
            StringCchCatW(args, ARRAYSIZE(args), L"\"");
        } else {
            PWSTR path = nullptr;
            if (count == 1) {
                IShellItem* item = nullptr;
                if (SUCCEEDED(items->GetItemAt(0, &item))) {
                    item->GetDisplayName(SIGDN_FILESYSPATH, &path);
                    item->Release();
                }
            } else if (folderFallback) {
                folderFallback->GetDisplayName(SIGDN_FILESYSPATH, &path);
            }
            if (!path) return E_FAIL;
            StringCchCatW(args, ARRAYSIZE(args), L" --path \"");
            StringCchCatW(args, ARRAYSIZE(args), path);
            StringCchCatW(args, ARRAYSIZE(args), L"\"");
            CoTaskMemFree(path);
        }
    }

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(exe, args, nullptr, nullptr, FALSE,
                        CREATE_NEW_PROCESS_GROUP, nullptr, nullptr, &si, &pi)) {
        return HRESULT_FROM_WIN32(GetLastError());
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return S_OK;
}

// ------------------------------------------------------------- subcommand
class RootCommand;  // fwd

class SubCommand : public IExplorerCommand {
public:
    SubCommand(Cmd cmd, RootCommand* root);

    // IUnknown
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) {
        if (riid == IID_IUnknown || riid == IID_IExplorerCommand) {
            *ppv = static_cast<IExplorerCommand*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&m_refs); }
    IFACEMETHODIMP_(ULONG) Release() {
        ULONG r = InterlockedDecrement(&m_refs);
        if (r == 0) delete this;
        return r;
    }

    // IExplorerCommand
    IFACEMETHODIMP GetTitle(IShellItemArray*, PWSTR* name) {
        if (m_cmd == Cmd::Undo) {
            // "Undo copy" / "Undo move" / "Undo mirror" when the marker knows what it was
            wchar_t verb[32];
            if (SUCCEEDED(ReadInstallString(L"LastUndoableVerb", verb, ARRAYSIZE(verb))) && verb[0]) {
                wchar_t t[64];
                StringCchPrintfW(t, ARRAYSIZE(t), L"Undo %s", verb);
                return SHStrDupW(t, name);
            }
        }
        return SHStrDupW(CmdTitle(m_cmd), name);
    }
    IFACEMETHODIMP GetIcon(IShellItemArray*, PWSTR*) { return E_NOTIMPL; }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, PWSTR*) { return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* guid) { *guid = CLSID_RobocopyToMenu; return S_OK; }
    IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state);
    IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*);
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) { *flags = ECF_DEFAULT; return S_OK; }
    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand**) { return E_NOTIMPL; }

    virtual ~SubCommand();

private:
    volatile LONG m_refs = 1;
    Cmd m_cmd;
    RootCommand* m_root;   // holds a strong ref for site-based folder lookup
};

// ----------------------------------------------------------- enumerator
class CommandEnum : public IEnumExplorerCommand {
public:
    CommandEnum(RootCommand* root);

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) {
        if (riid == IID_IUnknown || riid == IID_IEnumExplorerCommand) {
            *ppv = static_cast<IEnumExplorerCommand*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&m_refs); }
    IFACEMETHODIMP_(ULONG) Release() {
        ULONG r = InterlockedDecrement(&m_refs);
        if (r == 0) delete this;
        return r;
    }

    IFACEMETHODIMP Next(ULONG celt, IExplorerCommand** out, ULONG* fetched) {
        ULONG n = 0;
        while (n < celt && m_index < (ULONG)Cmd::Count) {
            out[n] = new (std::nothrow) SubCommand((Cmd)m_index, m_root);
            if (!out[n]) break;
            m_index++; n++;
        }
        if (fetched) *fetched = n;
        return (n == celt) ? S_OK : S_FALSE;
    }
    IFACEMETHODIMP Skip(ULONG celt) { m_index += celt; return S_OK; }
    IFACEMETHODIMP Reset() { m_index = 0; return S_OK; }
    IFACEMETHODIMP Clone(IEnumExplorerCommand**) { return E_NOTIMPL; }

    virtual ~CommandEnum();

private:
    volatile LONG m_refs = 1;
    ULONG m_index = 0;
    RootCommand* m_root;
};

// ----------------------------------------------------------- root command
class RootCommand : public IExplorerCommand, public IObjectWithSite {
public:
    RootCommand() { DllAddRef(); }

    // IUnknown
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) {
        if (riid == IID_IUnknown || riid == IID_IExplorerCommand) {
            *ppv = static_cast<IExplorerCommand*>(this);
        } else if (riid == IID_IObjectWithSite) {
            *ppv = static_cast<IObjectWithSite*>(this);
        } else {
            *ppv = nullptr;
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }
    IFACEMETHODIMP_(ULONG) AddRef() { return InterlockedIncrement(&m_refs); }
    IFACEMETHODIMP_(ULONG) Release() {
        ULONG r = InterlockedDecrement(&m_refs);
        if (r == 0) delete this;
        return r;
    }

    // IExplorerCommand
    IFACEMETHODIMP GetTitle(IShellItemArray*, PWSTR* name) { return SHStrDupW(L"Robocopy", name); }
    IFACEMETHODIMP GetIcon(IShellItemArray*, PWSTR*) { return E_NOTIMPL; }
    IFACEMETHODIMP GetToolTip(IShellItemArray*, PWSTR*) { return E_NOTIMPL; }
    IFACEMETHODIMP GetCanonicalName(GUID* guid) { *guid = CLSID_RobocopyToMenu; return S_OK; }
    IFACEMETHODIMP GetState(IShellItemArray*, BOOL, EXPCMDSTATE* state) { *state = ECS_ENABLED; return S_OK; }
    IFACEMETHODIMP Invoke(IShellItemArray*, IBindCtx*) { return S_OK; }  // flyout root never invokes
    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) { *flags = ECF_HASSUBCOMMANDS; return S_OK; }
    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** out) {
        *out = new (std::nothrow) CommandEnum(this);
        return *out ? S_OK : E_OUTOFMEMORY;
    }

    // IObjectWithSite
    IFACEMETHODIMP SetSite(IUnknown* site) {
        if (m_site) { m_site->Release(); m_site = nullptr; }
        m_site = site;
        if (m_site) m_site->AddRef();
        return S_OK;
    }
    IFACEMETHODIMP GetSite(REFIID riid, void** ppv) {
        if (!m_site) { *ppv = nullptr; return E_FAIL; }
        return m_site->QueryInterface(riid, ppv);
    }

    // background clicks pass no item array; resolve the browsed folder via the site chain
    HRESULT GetSiteFolder(IShellItem** out) {
        *out = nullptr;
        if (!m_site) return E_FAIL;
        IServiceProvider* sp = nullptr;
        HRESULT hr = m_site->QueryInterface(IID_PPV_ARGS(&sp));
        if (FAILED(hr)) return hr;
        IFolderView* fv = nullptr;
        hr = sp->QueryService(SID_SFolderView, IID_PPV_ARGS(&fv));
        sp->Release();
        if (FAILED(hr)) return hr;
        hr = fv->GetFolder(IID_PPV_ARGS(out));
        fv->Release();
        return hr;
    }

    virtual ~RootCommand() {
        if (m_site) m_site->Release();
        DllRelease();
    }

private:
    volatile LONG m_refs = 1;
    IUnknown* m_site = nullptr;
};

SubCommand::SubCommand(Cmd cmd, RootCommand* root) : m_cmd(cmd), m_root(root) {
    DllAddRef();
    if (m_root) m_root->AddRef();
}
SubCommand::~SubCommand() {
    if (m_root) m_root->Release();
    DllRelease();
}

CommandEnum::CommandEnum(RootCommand* root) : m_root(root) {
    DllAddRef();
    if (m_root) m_root->AddRef();
}
CommandEnum::~CommandEnum() {
    if (m_root) m_root->Release();
    DllRelease();
}

IFACEMETHODIMP SubCommand::GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) {
    *state = ECS_ENABLED;
    switch (m_cmd) {
    case Cmd::Robopaste:
        if (!ClipboardHasFiles()) *state = ECS_DISABLED;
        break;
    case Cmd::Undo:
        if (!HasUndoableOp()) *state = ECS_DISABLED;
        break;
    case Cmd::MirrorTo: {
        // mirroring a single file makes no sense; hide unless every item is a folder
        if (items) {
            DWORD count = 0;
            items->GetCount(&count);
            if (count > 0) {
                SFGAOF attrs = 0;
                // AND across the selection: set only when all items are folders
                if (SUCCEEDED(items->GetAttributes(SIATTRIBFLAGS_AND, SFGAO_FOLDER, &attrs))
                    ? (attrs & SFGAO_FOLDER) == 0 : false) {
                    *state = ECS_HIDDEN;
                }
            }
        }
        break;
    }
    default:
        break;
    }
    return S_OK;
}

IFACEMETHODIMP SubCommand::Invoke(IShellItemArray* items, IBindCtx*) {
    IShellItem* folder = nullptr;
    if (!items && m_root) m_root->GetSiteFolder(&folder);
    HRESULT hr = LaunchVerb(m_cmd, items, folder);
    if (folder) folder->Release();
    return hr;
}

// ------------------------------------------------------------ class factory
class Factory : public IClassFactory {
public:
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) {
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    IFACEMETHODIMP_(ULONG) AddRef() { return 2; }   // static lifetime
    IFACEMETHODIMP_(ULONG) Release() { return 1; }

    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) {
        *ppv = nullptr;
        if (outer) return CLASS_E_NOAGGREGATION;
        RootCommand* cmd = new (std::nothrow) RootCommand();
        if (!cmd) return E_OUTOFMEMORY;
        HRESULT hr = cmd->QueryInterface(riid, ppv);
        cmd->Release();
        return hr;
    }
    IFACEMETHODIMP LockServer(BOOL lock) {
        if (lock) DllAddRef(); else DllRelease();
        return S_OK;
    }
};

static Factory g_factory;

// ------------------------------------------------------------------ exports
STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** ppv) {
    if (clsid == CLSID_RobocopyToMenu) return g_factory.QueryInterface(riid, ppv);
    *ppv = nullptr;
    return CLASS_E_CLASSNOTAVAILABLE;
}

STDAPI DllCanUnloadNow() {
    return (g_refs == 0) ? S_OK : S_FALSE;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_module = (HMODULE)instance;
        DisableThreadLibraryCalls(instance);
    }
    return TRUE;
}
