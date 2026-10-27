#include "pch.h"
#include "BaritoneModule.h"
#include "BaritoneScript.h"
#include "Inflate.h"

// Lua is compiled as C++ (see CMakeLists.txt), so no extern "C" here
#include "lua/lua.h"
#include "lua/lualib.h"
#include "lua/lauxlib.h"

#include "client/event/events/TickEvent.h"
#include "client/event/events/RenderLayerEvent.h"
#include "client/event/events/RenderLevelEvent.h"
#include "client/event/events/ChatEvent.h"
#include "client/event/events/AfterMoveEvent.h"
#include "client/event/events/BeforeMoveEvent.h"
#include "mc/Addresses.h"
#include "client/event/events/KeyUpdateEvent.h"
#include "client/event/events/LeaveGameEvent.h"
#include "client/misc/Notifications.h"
#include "client/screen/ScreenManager.h"
#include "mc/common/client/game/Platform_GameCore.h"
#include "mc/common/client/renderer/MaterialPtr.h"
#include "mc/common/world/ItemStack.h"
#include "mc/common/world/actor/player/PlayerInventory.h"
#include "mc/common/world/level/BlockSource.h"
#include "mc/common/world/level/HitResult.h"
#include "mc/common/world/level/block/Block.h"
#include "mc/common/world/level/block/BlockLegacy.h"
#include "util/DrawUtil3D.h"
#include "util/Logger.h"
#include "util/Util.h"

#include <unordered_map>

BaritoneModule* BaritoneModule::instance = nullptr;

// ============================================================================
// Helpers
// ============================================================================
namespace {
    using Clock = std::chrono::steady_clock;

    Clock::time_point g_start = Clock::now();
    Clock::time_point g_callStart = Clock::now();
    bool g_inCall = false;

    double nowMs() {
        return std::chrono::duration<double, std::milli>(Clock::now() - g_start).count();
    }

    SDK::ClientInstance* client() {
        return SDK::ClientInstance::get();
    }

    SDK::LocalPlayer* localPlayer() {
        auto ci = client();
        return ci ? ci->getLocalPlayer() : nullptr;
    }

    SDK::Level* level() {
        auto ci = client();
        if (!ci || !ci->minecraft) return nullptr;
        return ci->minecraft->getLevel();
    }

    std::string stripNamespace(std::string s) {
        auto c = s.find(':');
        if (c != std::string::npos) s.erase(0, c + 1);
        return s;
    }

    // --- crash-guarded game calls (SEH; keep these free of C++ objects) ---
    SDK::BlockLegacy* sehLegacyAt(SDK::BlockSource* region, int x, int y, int z, bool* crashed) {
        __try {
            SDK::Block* b = region->getBlock(x, y, z);
            if (!b) return nullptr;
            return b->getBlockType();
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            *crashed = true;
            return nullptr;
        }
    }

    bool sehTurn(SDK::LocalPlayer* lp, float dx, float dy) {
        __try {
            Vec2 d { dx, dy };
            lp->applyTurnDelta(d);
            return true;
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            return false;
        }
    }

    std::unordered_map<SDK::BlockLegacy*, std::string> g_blockNames;
    int g_blockCrashes = 0;

    std::string const& blockNameOf(SDK::BlockLegacy* legacy) {
        static const std::string air = "air";
        if (!legacy) return air;
        auto it = g_blockNames.find(legacy);
        if (it != g_blockNames.end()) return it->second;
        std::string n = stripNamespace(legacy->name.getString());
        if (n.empty()) n = "air";
        return g_blockNames.emplace(legacy, std::move(n)).first->second;
    }

    std::string itemName(SDK::ItemStack* stack) {
        if (!stack || !stack->valid || stack->itemCount == 0) return {};
        SDK::Item* item = stack->getItem();
        if (!item) return {};
        return stripNamespace(item->id.getString());
    }

    // Feet position of an actor (Bedrock stores players' position at eye level)
    Vec3 feetPos(SDK::Actor* a, bool isPlayer) {
        Vec3 p = a->getPos();
        SDK::AABBShapeComponent* box = a->aabbShape;
        if (box) {
            float lowY = box->boundingBox.lower.y;
            if (std::abs((p.y - (isPlayer ? 1.62f : 0.f)) - lowY) < 2.5f) p.y = lowY;
            else if (isPlayer) p.y -= 1.62f;
        } else if (isPlayer) {
            p.y -= 1.62f;
        }
        return p;
    }

    // --- paths: everything the script touches lives under %LOCALAPPDATA%\Latite ---
    std::string pathToUtf8(std::filesystem::path const& p) {
        return util::WStrToStr(p.wstring());
    }

    bool resolvePath(std::string const& rel, std::filesystem::path& out) {
        std::filesystem::path p { util::StrToWStr(rel) };
        if (p.is_absolute() || p.has_root_name() || p.has_root_directory()) return false;
        for (auto const& part : p) {
            if (part == "..") return false;
        }
        out = util::GetLatitePath() / p;
        return true;
    }

    bool readWholeFile(std::filesystem::path const& p, std::string& out) {
        std::ifstream f(p, std::ios::binary);
        if (!f) return false;
        std::ostringstream ss;
        ss << f.rdbuf();
        out = ss.str();
        return true;
    }

    // --- SendInput (clicks and hotbar keys) ---
    void sendMouse(DWORD flags) {
        INPUT in {};
        in.type = INPUT_MOUSE;
        in.mi.dwFlags = flags;
        SendInput(1, &in, sizeof(INPUT));
    }

    void sendKey(WORD vk, bool down) {
        INPUT in {};
        in.type = INPUT_KEYBOARD;
        in.ki.wScan = static_cast<WORD>(MapVirtualKeyW(vk, MAPVK_VK_TO_VSC));
        in.ki.dwFlags = KEYEVENTF_SCANCODE | (down ? 0 : KEYEVENTF_KEYUP);
        // right-hand Ctrl/Alt and the arrow keys etc. need the extended flag
        if (vk == VK_RCONTROL || vk == VK_RMENU || (vk >= VK_PRIOR && vk <= VK_DOWN) || vk == VK_INSERT ||
            vk == VK_DELETE) {
            in.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
        }
        SendInput(1, &in, sizeof(INPUT));
    }

    void sendMouseMove(int dx, int dy) {
        INPUT in {};
        in.type = INPUT_MOUSE;
        in.mi.dx = dx;
        in.mi.dy = dy;
        in.mi.dwFlags = MOUSEEVENTF_MOVE;
        SendInput(1, &in, sizeof(INPUT));
    }

    BaritoneModule* mod() {
        return BaritoneModule::instance;
    }

    // ========================================================================
    // Lua bindings
    // ========================================================================
    void setField(lua_State* L, const char* k, double v) {
        lua_pushnumber(L, v);
        lua_setfield(L, -2, k);
    }

    void setField(lua_State* L, const char* k, std::string const& v) {
        lua_pushlstring(L, v.data(), v.size());
        lua_setfield(L, -2, k);
    }

    void setFieldBool(lua_State* L, const char* k, bool v) {
        lua_pushboolean(L, v);
        lua_setfield(L, -2, k);
    }

    // ---------------- player ----------------
    int l_player_name(lua_State* L) {
        auto lp = localPlayer();
        if (!lp) {
            lua_pushstring(L, "");
            return 1;
        }
        std::string n = lp->playerName;
        lua_pushlstring(L, n.data(), n.size());
        return 1;
    }

    int l_player_position(lua_State* L) {
        auto lp = localPlayer();
        if (!lp) {
            lua_pushnumber(L, 0);
            lua_pushnumber(L, 0);
            lua_pushnumber(L, 0);
            return 3;
        }
        Vec3 p = feetPos(lp, true);
        lua_pushnumber(L, p.x);
        lua_pushnumber(L, p.y);
        lua_pushnumber(L, p.z);
        return 3;
    }

    int l_player_rotation(lua_State* L) {
        lua_createtable(L, 0, 2);
        auto lp = localPlayer();
        Vec2 r = lp ? lp->getRot() : Vec2 {};
        setField(L, "x", r.x); // pitch
        setField(L, "y", r.y); // yaw
        return 1;
    }

    int l_player_velocity(lua_State* L) {
        auto lp = localPlayer();
        Vec3 v = lp ? lp->getVelocity() : Vec3 {};
        lua_pushnumber(L, v.x);
        lua_pushnumber(L, v.y);
        lua_pushnumber(L, v.z);
        return 3;
    }

    int l_player_health(lua_State* L) {
        auto lp = localPlayer();
        lua_pushnumber(L, lp ? lp->getHealth().value_or(-1.f) : -1.f);
        return 1;
    }

    int l_player_hunger(lua_State* L) {
        auto lp = localPlayer();
        lua_pushnumber(L, lp ? lp->getHunger().value_or(20.f) : -1.f);
        return 1;
    }

    int l_player_gamemode(lua_State* L) {
        lua_pushinteger(L, 0); // not exposed by the SDK; survival rules are safe for every mode
        return 1;
    }

    int l_player_selectedSlot(lua_State* L) {
        auto lp = localPlayer();
        int slot = 0;
        if (lp && lp->supplies) slot = lp->supplies->selectedSlot;
        lua_pushinteger(L, slot);
        return 1;
    }

    void pushItemTable(lua_State* L, std::string const& name, int count) {
        lua_createtable(L, 0, 2);
        setField(L, "name", name.empty() ? std::string("empty") : name);
        setField(L, "count", count);
    }

    int l_player_mainhand(lua_State* L) {
        auto lp = localPlayer();
        if (!lp || !lp->supplies || !lp->supplies->inventory) {
            pushItemTable(L, "", 0);
            return 1;
        }
        auto stack = lp->supplies->inventory->getItem(lp->supplies->selectedSlot);
        pushItemTable(L, itemName(stack), stack ? stack->itemCount : 0);
        return 1;
    }

    int l_player_armor(lua_State* L) {
        lua_createtable(L, 0, 4);
        auto lp = localPlayer();
        static const char* slots[4] = { "helmet", "chestplate", "leggings", "boots" };
        for (int i = 0; i < 4; i++) {
            std::string n;
            if (lp) n = itemName(lp->getArmor(i));
            pushItemTable(L, n, n.empty() ? 0 : 1);
            lua_setfield(L, -2, slots[i]);
        }
        return 1;
    }

    // hotbar: { [0] = "diamond_pickaxe" | false, ... [8] }
    int l_player_hotbar(lua_State* L) {
        lua_createtable(L, 0, 9);
        auto lp = localPlayer();
        auto inv = (lp && lp->supplies) ? lp->supplies->inventory : nullptr;
        for (int i = 0; i < 9; i++) {
            std::string n = inv ? itemName(inv->getItem(i)) : std::string();
            if (n.empty()) lua_pushboolean(L, 0);
            else lua_pushlstring(L, n.data(), n.size());
            lua_rawseti(L, -2, i);
        }
        return 1;
    }

    // inventory: { [0..35] = { name =, count = } }
    int l_player_inventory(lua_State* L) {
        lua_createtable(L, 0, 36);
        auto lp = localPlayer();
        auto inv = (lp && lp->supplies) ? lp->supplies->inventory : nullptr;
        if (!inv) return 1;
        for (int i = 0; i < 36; i++) {
            auto stack = inv->getItem(i);
            std::string n = itemName(stack);
            if (n.empty()) continue;
            pushItemTable(L, n, stack->itemCount);
            lua_rawseti(L, -2, i);
        }
        return 1;
    }

    int l_player_dimension(lua_State* L) {
        auto lp = localPlayer();
        std::string d = "overworld";
        if (lp) {
            std::shared_ptr<SDK::Dimension> dim = lp->dimension;
            if (dim) d = dim->dimensionName;
        }
        lua_pushlstring(L, d.data(), d.size());
        return 1;
    }

    // ---------------- world ----------------
    int l_world_getBlock(lua_State* L) {
        int x = static_cast<int>(std::floor(luaL_checknumber(L, 1)));
        int y = static_cast<int>(std::floor(luaL_checknumber(L, 2)));
        int z = static_cast<int>(std::floor(luaL_checknumber(L, 3)));
        auto ci = client();
        SDK::BlockSource* region = ci ? ci->getRegion() : nullptr;
        if (!region || !localPlayer()) {
            lua_pushstring(L, "air");
            return 1;
        }
        bool crashed = false;
        SDK::BlockLegacy* legacy = sehLegacyAt(region, x, y, z, &crashed);
        if (crashed) {
            if (g_blockCrashes++ < 3) Logger::Warn("[Baritone] getBlock crashed at {} {} {}", x, y, z);
            lua_pushstring(L, "air");
            return 1;
        }
        std::string const& n = blockNameOf(legacy);
        lua_pushlstring(L, n.data(), n.size());
        return 1;
    }

    int l_world_raycast(lua_State* L) {
        double maxDist = luaL_optnumber(L, 1, 6.0);
        auto lvl = level();
        auto lp = localPlayer();
        if (!lvl || !lp) return 0;
        SDK::HitResult* hr = lvl->getHitResult();
        if (!hr || hr->hitType != SDK::HitType::BLOCK) return 0;
        Vec3 eye = lp->getPos();
        float dist = eye.distance(hr->hitPos);
        if (dist > maxDist) return 0;
        lua_createtable(L, 0, 9);
        setField(L, "blockX", hr->hitBlock.x);
        setField(L, "blockY", hr->hitBlock.y);
        setField(L, "blockZ", hr->hitBlock.z);
        setField(L, "faceId", static_cast<int>(hr->face));
        setField(L, "face", static_cast<int>(hr->face));
        setField(L, "x", hr->hitPos.x);
        setField(L, "y", hr->hitPos.y);
        setField(L, "z", hr->hitPos.z);
        setField(L, "distance", dist);
        return 1;
    }

    int l_world_getWorldName(lua_State* L) {
        auto lvl = level();
        std::string n;
        if (lvl) n = lvl->getLevelName();
        lua_pushlstring(L, n.data(), n.size());
        return 1;
    }

    int l_world_getDimension(lua_State* L) {
        return l_player_dimension(L);
    }

    // { { name, type, x, y, z, dist, player }, ... }  (positions are feet positions)
    int l_world_getEntities(lua_State* L) {
        double maxDist = luaL_optnumber(L, 1, 128.0);
        lua_newtable(L);
        auto lvl = level();
        auto lp = localPlayer();
        if (!lvl || !lp) return 1;
        Vec3 me = lp->getPos();
        int idx = 1;
        for (SDK::Actor* a : lvl->getRuntimeActorList()) {
            if (!a || a == lp) continue;
            bool isPlayer = a->isPlayer();
            Vec3 p = feetPos(a, isPlayer);
            Vec3 eyeish = a->getPos();
            float d = me.distance(eyeish);
            if (maxDist > 0 && d > maxDist) continue;
            std::string name;
            if (isPlayer) name = reinterpret_cast<SDK::Player*>(a)->playerName;
            if (name.empty()) name = a->getNameTag();
            std::string type = a->getEntityTypeName();
            lua_createtable(L, 0, 7);
            setField(L, "name", name);
            setField(L, "type", type.empty() ? std::string(isPlayer ? "minecraft:player" : "unknown") : type);
            setField(L, "x", p.x);
            setField(L, "y", p.y);
            setField(L, "z", p.z);
            setField(L, "dist", d);
            setFieldBool(L, "player", isPlayer);
            lua_rawseti(L, -2, idx++);
        }
        return 1;
    }

    // ---------------- client / util / log ----------------
    int l_client_displayLocalMessage(lua_State* L) {
        size_t len = 0;
        const char* s = luaL_checklstring(L, 1, &len);
        if (mod()) mod()->chat(std::string(s, len));
        return 0;
    }

    int l_client_notify(lua_State* L) {
        size_t len = 0;
        const char* s = luaL_checklstring(L, 1, &len);
        Latite::getNotifications().push(util::StrToWStr(std::string(s, len)));
        return 0;
    }

    int l_client_getScreenName(lua_State* L) {
        bool hud = mod() && mod()->isInHud();
        lua_pushstring(L, hud ? "hud_screen" : "menu_screen");
        return 1;
    }

    int l_client_isInGame(lua_State* L) {
        lua_pushboolean(L, localPlayer() != nullptr);
        return 1;
    }

    int l_util_time(lua_State* L) {
        lua_pushnumber(L, nowMs());
        return 1;
    }

    int l_log(lua_State* L) {
        int n = lua_gettop(L);
        std::string out;
        for (int i = 1; i <= n; i++) {
            size_t len = 0;
            const char* s = luaL_tolstring(L, i, &len);
            if (i > 1) out += ' ';
            out.append(s, len);
            lua_pop(L, 1);
        }
        Logger::Info("[Baritone] {}", out);
        return 0;
    }

    int l_print(lua_State* L) {
        int n = lua_gettop(L);
        std::string out;
        for (int i = 1; i <= n; i++) {
            size_t len = 0;
            const char* s = luaL_tolstring(L, i, &len);
            if (i > 1) out += ' ';
            out.append(s, len);
            lua_pop(L, 1);
        }
        if (mod()) mod()->chat(out);
        return 0;
    }

    // ---------------- fs (sandboxed to %LOCALAPPDATA%\Latite) ----------------
    int l_fs_exists(lua_State* L) {
        std::filesystem::path p;
        std::error_code ec;
        lua_pushboolean(L, resolvePath(luaL_checkstring(L, 1), p) && std::filesystem::exists(p, ec));
        return 1;
    }

    int l_fs_isDirectory(lua_State* L) {
        std::filesystem::path p;
        std::error_code ec;
        lua_pushboolean(L, resolvePath(luaL_checkstring(L, 1), p) && std::filesystem::is_directory(p, ec));
        return 1;
    }

    int l_fs_create(lua_State* L) {
        std::filesystem::path p;
        std::error_code ec;
        bool ok = resolvePath(luaL_checkstring(L, 1), p);
        if (ok) {
            std::filesystem::create_directories(p, ec);
            ok = std::filesystem::is_directory(p, ec);
        }
        lua_pushboolean(L, ok);
        return 1;
    }

    int l_fs_remove(lua_State* L) {
        std::filesystem::path p;
        std::error_code ec;
        bool ok = resolvePath(luaL_checkstring(L, 1), p) && std::filesystem::is_regular_file(p, ec) &&
                  std::filesystem::remove(p, ec);
        lua_pushboolean(L, ok);
        return 1;
    }

    int l_fs_readFile(lua_State* L) {
        std::filesystem::path p;
        std::string data;
        if (resolvePath(luaL_checkstring(L, 1), p) && readWholeFile(p, data)) {
            lua_pushlstring(L, data.data(), data.size());
        } else {
            lua_pushstring(L, "");
        }
        return 1;
    }

    // Reads a file and transparently decompresses gzip / zlib (schematics).
    int l_fs_readBinary(lua_State* L) {
        std::filesystem::path p;
        std::string data, out;
        if (!resolvePath(luaL_checkstring(L, 1), p) || !readWholeFile(p, data)) {
            lua_pushnil(L);
            lua_pushstring(L, "can't read file");
            return 2;
        }
        if (!baritone::Inflater::decompressAuto(data, out)) {
            lua_pushnil(L);
            lua_pushstring(L, "corrupt compressed data");
            return 2;
        }
        lua_pushlstring(L, out.data(), out.size());
        return 1;
    }

    int l_fs_writeFile(lua_State* L) {
        std::filesystem::path p;
        size_t len = 0;
        const char* rel = luaL_checkstring(L, 1);
        const char* content = luaL_checklstring(L, 2, &len);
        bool ok = false;
        if (resolvePath(rel, p)) {
            std::error_code ec;
            std::filesystem::create_directories(p.parent_path(), ec);
            std::ofstream f(p, std::ios::binary | std::ios::trunc);
            if (f) {
                f.write(content, static_cast<std::streamsize>(len));
                ok = static_cast<bool>(f);
            }
        }
        lua_pushboolean(L, ok);
        return 1;
    }

    int l_fs_listDirectory(lua_State* L) {
        lua_newtable(L);
        std::filesystem::path p;
        std::string rel = luaL_checkstring(L, 1);
        std::error_code ec;
        if (!resolvePath(rel, p) || !std::filesystem::is_directory(p, ec)) return 1;
        int i = 1;
        for (auto const& e : std::filesystem::directory_iterator(p, ec)) {
            std::string name = pathToUtf8(e.path().filename());
            std::string full = rel + "/" + name;
            lua_pushlstring(L, full.data(), full.size());
            lua_rawseti(L, -2, i++);
        }
        return 1;
    }

    // ---------------- events / commands ----------------
    int l_onEvent(lua_State* L) {
        luaL_checkstring(L, 1);
        luaL_checktype(L, 2, LUA_TFUNCTION);
        lua_getfield(L, LUA_REGISTRYINDEX, "BaritoneEvents");
        lua_pushvalue(L, 1);
        lua_pushvalue(L, 2);
        lua_settable(L, -3);
        lua_pop(L, 1);
        return 0;
    }

    int l_registerCommand(lua_State*) {
        return 0; // '#' commands come through the chat hook
    }

    // ---------------- native input / rendering ----------------
    // native.setInput(active, forward, back, left, right, jump, sneak, sprint)
    int l_native_setInput(lua_State* L) {
        auto m = mod();
        if (!m) return 0;
        std::lock_guard lock { m->stateMutex };
        m->move.active = lua_toboolean(L, 1);
        m->move.forward = lua_toboolean(L, 2);
        m->move.back = lua_toboolean(L, 3);
        m->move.left = lua_toboolean(L, 4);
        m->move.right = lua_toboolean(L, 5);
        m->move.jump = lua_toboolean(L, 6);
        m->move.sneak = lua_toboolean(L, 7);
        m->move.sprint = lua_toboolean(L, 8);
        return 0;
    }

    // native.setButtons(lmbHeld, rmbHeld)
    int l_native_setButtons(lua_State* L) {
        auto m = mod();
        if (!m) return 0;
        std::lock_guard lock { m->stateMutex };
        m->lmbWanted = lua_toboolean(L, 1);
        m->rmbWanted = lua_toboolean(L, 2);
        return 0;
    }

    // native.click(button)  1 = left (attack/break), 2 = right (use/place)
    int l_native_click(lua_State* L) {
        auto m = mod();
        int b = static_cast<int>(luaL_checkinteger(L, 1));
        if (!m || b < 1 || b > 2) return 0;
        std::lock_guard lock { m->stateMutex };
        if (m->pendingClicks[b] < 4) m->pendingClicks[b]++;
        return 0;
    }

    // native.selectSlot(0..8) - presses the hotbar key
    int l_native_selectSlot(lua_State* L) {
        auto m = mod();
        int s = static_cast<int>(luaL_checkinteger(L, 1));
        if (!m || s < 0 || s > 8) return 0;
        std::lock_guard lock { m->stateMutex };
        m->pendingSlot = s;
        return 0;
    }

    // native.setRotation(pitch, yaw) - writes the player's rotation directly
    int l_native_setRotation(lua_State* L) {
        float pitch = static_cast<float>(luaL_checknumber(L, 1));
        float yaw = static_cast<float>(luaL_checknumber(L, 2));
        auto lp = localPlayer();
        if (!lp || !lp->actorRotation) return 0;
        pitch = std::clamp(pitch, -89.9f, 89.9f);
        auto rot = lp->actorRotation;
        rot->rotation = Vec2 { pitch, yaw };
        rot->rotationOld = Vec2 { pitch, yaw };
        return 0;
    }

    // native.turn(dx, dy) - turns through the game's mouse-look path
    int l_native_turn(lua_State* L) {
        float dx = static_cast<float>(luaL_checknumber(L, 1));
        float dy = static_cast<float>(luaL_checknumber(L, 2));
        auto lp = localPlayer();
        bool ok = lp && sehTurn(lp, dx, dy);
        lua_pushboolean(L, ok);
        return 1;
    }

    int l_native_focused(lua_State* L) {
        lua_pushboolean(L, mod() && mod()->isGameFocused());
        return 1;
    }

    int l_native_panicCount(lua_State* L) {
        lua_pushinteger(L, mod() ? mod()->panicCount.load() : 0);
        return 1;
    }

    // native.setLines({ x1,y1,z1, x2,y2,z2, r,g,b,a,  ... })  colours 0-255
    int l_native_setLines(lua_State* L) {
        auto m = mod();
        if (!m) return 0;
        luaL_checktype(L, 1, LUA_TTABLE);
        lua_Integer n = luaL_len(L, 1);
        std::vector<BaritoneModule::Line> lines;
        lines.reserve(static_cast<size_t>(n / 10));
        for (lua_Integer i = 1; i + 9 <= n; i += 10) {
            float v[10];
            for (int k = 0; k < 10; k++) {
                lua_rawgeti(L, 1, i + k);
                v[k] = static_cast<float>(lua_tonumber(L, -1));
                lua_pop(L, 1);
            }
            lines.push_back({ v[0], v[1], v[2], v[3], v[4], v[5], v[6] / 255.f, v[7] / 255.f, v[8] / 255.f,
                              v[9] / 255.f });
        }
        std::lock_guard lock { m->stateMutex };
        m->lines = std::move(lines);
        return 0;
    }

    // native.setBoxes({ x1,y1,z1, x2,y2,z2, r,g,b,a, fill,  ... })  colours and alphas 0-255
    int l_native_setBoxes(lua_State* L) {
        auto m = mod();
        if (!m) return 0;
        luaL_checktype(L, 1, LUA_TTABLE);
        lua_Integer n = luaL_len(L, 1);
        std::vector<BaritoneModule::Box> boxes;
        boxes.reserve(static_cast<size_t>(n / 11));
        for (lua_Integer i = 1; i + 10 <= n; i += 11) {
            float v[11];
            for (int k = 0; k < 11; k++) {
                lua_rawgeti(L, 1, i + k);
                v[k] = static_cast<float>(lua_tonumber(L, -1));
                lua_pop(L, 1);
            }
            boxes.push_back({ v[0], v[1], v[2], v[3], v[4], v[5], v[6] / 255.f, v[7] / 255.f, v[8] / 255.f,
                              v[9] / 255.f, v[10] / 255.f });
        }
        std::lock_guard lock { m->stateMutex };
        m->boxes = std::move(boxes);
        return 0;
    }

    // native.setInputMode("hook" | "keys")
    //   hook: write the game's movement input state (default)
    //   keys: press the real movement keys (fallback if the hook doesn't move the player)
    int l_native_setInputMode(lua_State* L) {
        auto m = mod();
        if (!m) return 0;
        std::string mode = luaL_checkstring(L, 1);
        std::lock_guard lock { m->stateMutex };
        m->inputMode = (mode == "keys") ? BaritoneModule::InputMode::Keys : BaritoneModule::InputMode::Hook;
        return 0;
    }

    // native.setMoveKeys(forward, back, left, right, jump, sneak, sprint) - virtual-key codes for keys mode
    int l_native_setMoveKeys(lua_State* L) {
        auto m = mod();
        if (!m) return 0;
        std::lock_guard lock { m->stateMutex };
        for (int i = 0; i < 7; i++) {
            lua_Integer vk = luaL_optinteger(L, i + 1, 0);
            if (vk > 0 && vk < 256) m->moveKeys[i] = static_cast<unsigned short>(vk);
        }
        return 0;
    }

    // native.mouseMove(dx, dy) - a real relative mouse movement (only while the game is focused, in the HUD)
    int l_native_mouseMove(lua_State* L) {
        int dx = static_cast<int>(luaL_checknumber(L, 1));
        int dy = static_cast<int>(luaL_checknumber(L, 2));
        auto m = mod();
        bool ok = m && m->isGameFocused() && m->isInHud();
        if (ok && (dx != 0 || dy != 0)) sendMouseMove(dx, dy);
        lua_pushboolean(L, ok);
        return 1;
    }

    // native.stats() - diagnostics for #debug and the automatic fallbacks
    int l_native_stats(lua_State* L) {
        auto m = mod();
        lua_createtable(L, 0, 20);
        if (!m) return 1;
        double now = nowMs();
        auto age = [now](long long t) { return t < 0 ? -1.0 : now - static_cast<double>(t); };
        setField(L, "tickAge", age(m->lastTickMs.load()));
        setField(L, "moveAge", age(m->lastMoveMs.load()));
        setFieldBool(L, "focused", m->isGameFocused());
        setFieldBool(L, "inHud", m->isInHud());
        auto ci = client();
        setFieldBool(L, "cursorGrabbed", ci && ci->minecraftGame && ci->minecraftGame->isCursorGrabbed());
        setFieldBool(L, "latiteMenu", Latite::getScreenManager().getActiveScreen().has_value());
        setFieldBool(L, "deadTick", Signatures::MultiPlayerLevel__subTick.result == 0);
        setFieldBool(L, "deadMove", Signatures::ClientInputUpdateSystemInternal_tickUpdateClientInput.result == 0);
        setFieldBool(L, "deadTurn", Signatures::LocalPlayer_applyTurnDelta.result == 0);
        setFieldBool(L, "deadMouse", Signatures::GameCore_handleMouseInput.result == 0);
        auto lp = localPlayer();
        setFieldBool(L, "rotationComponent", lp != nullptr && lp->actorRotation != nullptr);
        std::lock_guard lock { m->stateMutex };
        setField(L, "inputMode", std::string(m->inputMode == BaritoneModule::InputMode::Keys ? "keys" : "hook"));
        setField(L, "lines", static_cast<double>(m->lines.size()));
        setField(L, "boxes", static_cast<double>(m->boxes.size()));
        setFieldBool(L, "moveActive", m->move.active);
        return 1;
    }

    // native.setStatus(text, visible)
    int l_native_setStatus(lua_State* L) {
        auto m = mod();
        if (!m) return 0;
        size_t len = 0;
        const char* s = luaL_optlstring(L, 1, "", &len);
        std::wstring w = util::StrToWStr(std::string(s, len));
        std::lock_guard lock { m->stateMutex };
        m->statusText = std::move(w);
        m->statusVisible = lua_toboolean(L, 2);
        return 0;
    }

    void registerTable(lua_State* L, const char* name, const luaL_Reg* funcs) {
        lua_newtable(L);
        luaL_setfuncs(L, funcs, 0);
        lua_setglobal(L, name);
    }

    // Stops runaway scripts from freezing the game
    void timeoutHook(lua_State* L, lua_Debug*) {
        if (g_inCall && Clock::now() - g_callStart > std::chrono::milliseconds(400)) {
            luaL_error(L, "script took too long (over 400 ms) and was interrupted");
        }
    }

    int traceback(lua_State* L) {
        const char* msg = lua_tostring(L, 1);
        luaL_traceback(L, L, msg ? msg : "(error object)", 1);
        return 1;
    }
}

// ============================================================================
// Module
// ============================================================================
BaritoneModule::BaritoneModule()
    : TextModule("Baritone", L"Baritone",
                 L"Baritone-style pathfinding bot. Type #help in chat. #goto, #mine, #follow, #build, #farm, #elytra, #stop",
                 GAMEHUD, 500.f, 0, false) {
    instance = this;
    enabled = BoolValue(true); // on by default so #commands work straight away

    addSetting("stopKey", L"Stop key", L"Stops whatever the bot is doing (same as #stop)", stopKey);
    addSetting("showStatus", L"Show status", L"Show what the bot is doing on the HUD while it's active", showStatus);
    addSetting("renderPath", L"Render path", L"Draw the path, goal and schematic in the world", renderPath);

    listen<TickEvent>(static_cast<EventListenerFunc>(&BaritoneModule::onTick));
    listen<RenderLayerEvent>(static_cast<EventListenerFunc>(&BaritoneModule::onRenderLayer));
    listen<RenderLevelEvent>(static_cast<EventListenerFunc>(&BaritoneModule::onRenderLevel));
    listen<ChatEvent>(static_cast<EventListenerFunc>(&BaritoneModule::onChat));
    listen<AfterMoveEvent>(static_cast<EventListenerFunc>(&BaritoneModule::onAfterMove));
    listen<BeforeMoveEvent>(static_cast<EventListenerFunc>(&BaritoneModule::onBeforeMove));
    listen<KeyUpdateEvent>(static_cast<EventListenerFunc>(&BaritoneModule::onKey), true);
    listen<LeaveGameEvent>(static_cast<EventListenerFunc>(&BaritoneModule::onLeaveGame), true);
}

BaritoneModule::~BaritoneModule() {
    stopLua();
    if (instance == this) instance = nullptr;
}

std::string const& BaritoneModule::dataDir() {
    static std::string dir = pathToUtf8(util::GetLatitePath() / "Baritone");
    return dir;
}

bool BaritoneModule::isGameFocused() {
    auto platform = SDK::Platform_GameCore::get();
    auto core = platform ? platform->getGameCore() : nullptr;
    HWND hwnd = core ? core->hwnd : nullptr;
    if (!hwnd || !IsWindow(hwnd)) return GetForegroundWindow() != nullptr; // can't tell - assume yes
    HWND fg = GetForegroundWindow();
    return fg == hwnd || GetAncestor(fg, GA_ROOT) == GetAncestor(hwnd, GA_ROOT);
}

bool BaritoneModule::isInHud() {
    auto ci = client();
    if (!ci || !ci->getLocalPlayer() || !ci->minecraftGame) return false;
    if (Latite::getScreenManager().getActiveScreen()) return false; // a Latite menu is open
    return ci->minecraftGame->isCursorGrabbed();
}

void BaritoneModule::chat(std::string const& msg) {
    if (Latite::isMainThread()) {
        Latite::getClientMessageQueue().display(msg);
    } else {
        Latite::getClientMessageQueue().push(msg);
    }
}

void BaritoneModule::reportLuaError(std::string const& where, std::string const& err) {
    Logger::Warn("[Baritone] {}: {}", where, err);
    auto now = Clock::now();
    if (now - lastErrorTime > std::chrono::seconds(3)) {
        lastErrorTime = now;
        std::string first = err.substr(0, err.find('\n'));
        chat("\xC2\xA7" "c[Baritone] " + where + ": " + first);
    }
}

bool BaritoneModule::startLua() {
    std::lock_guard lock { luaMutex };
    if (L) return true;

    L = luaL_newstate();
    if (!L) {
        luaFailed = true;
        return false;
    }

    // only the safe standard libraries (no io / os / package / debug)
    const luaL_Reg libs[] = { { LUA_GNAME, luaopen_base },          { LUA_TABLIBNAME, luaopen_table },
                              { LUA_STRLIBNAME, luaopen_string },   { LUA_MATHLIBNAME, luaopen_math },
                              { LUA_COLIBNAME, luaopen_coroutine }, { LUA_UTF8LIBNAME, luaopen_utf8 },
                              { nullptr, nullptr } };
    for (const luaL_Reg* lib = libs; lib->func; lib++) {
        luaL_requiref(L, lib->name, lib->func, 1);
        lua_pop(L, 1);
    }
    // remove file-loading base functions
    lua_pushnil(L);
    lua_setglobal(L, "dofile");
    lua_pushnil(L);
    lua_setglobal(L, "loadfile");

    lua_newtable(L);
    lua_setfield(L, LUA_REGISTRYINDEX, "BaritoneEvents");

    static const luaL_Reg playerFns[] = { { "name", l_player_name },
                                          { "position", l_player_position },
                                          { "rotation", l_player_rotation },
                                          { "velocity", l_player_velocity },
                                          { "health", l_player_health },
                                          { "hunger", l_player_hunger },
                                          { "gamemode", l_player_gamemode },
                                          { "selectedSlot", l_player_selectedSlot },
                                          { "mainhand", l_player_mainhand },
                                          { "armor", l_player_armor },
                                          { "hotbar", l_player_hotbar },
                                          { "inventory", l_player_inventory },
                                          { "dimension", l_player_dimension },
                                          { nullptr, nullptr } };
    static const luaL_Reg worldFns[] = { { "getBlock", l_world_getBlock },
                                         { "raycast", l_world_raycast },
                                         { "getWorldName", l_world_getWorldName },
                                         { "getDimension", l_world_getDimension },
                                         { "getEntities", l_world_getEntities },
                                         { nullptr, nullptr } };
    static const luaL_Reg clientFns[] = { { "displayLocalMessage", l_client_displayLocalMessage },
                                          { "notify", l_client_notify },
                                          { "getScreenName", l_client_getScreenName },
                                          { "isInGame", l_client_isInGame },
                                          { nullptr, nullptr } };
    static const luaL_Reg utilFns[] = { { "time", l_util_time }, { nullptr, nullptr } };
    static const luaL_Reg fsFns[] = { { "exists", l_fs_exists },
                                      { "isDirectory", l_fs_isDirectory },
                                      { "create", l_fs_create },
                                      { "remove", l_fs_remove },
                                      { "readFile", l_fs_readFile },
                                      { "readBinary", l_fs_readBinary },
                                      { "writeFile", l_fs_writeFile },
                                      { "listDirectory", l_fs_listDirectory },
                                      { nullptr, nullptr } };
    static const luaL_Reg nativeFns[] = { { "setInput", l_native_setInput },
                                          { "setButtons", l_native_setButtons },
                                          { "click", l_native_click },
                                          { "selectSlot", l_native_selectSlot },
                                          { "setRotation", l_native_setRotation },
                                          { "turn", l_native_turn },
                                          { "focused", l_native_focused },
                                          { "panicCount", l_native_panicCount },
                                          { "setLines", l_native_setLines },
                                          { "setStatus", l_native_setStatus },
                                          { "setBoxes", l_native_setBoxes },
                                          { "setInputMode", l_native_setInputMode },
                                          { "setMoveKeys", l_native_setMoveKeys },
                                          { "mouseMove", l_native_mouseMove },
                                          { "stats", l_native_stats },
                                          { nullptr, nullptr } };
    registerTable(L, "player", playerFns);
    registerTable(L, "world", worldFns);
    registerTable(L, "client", clientFns);
    registerTable(L, "util", utilFns);
    registerTable(L, "fs", fsFns);
    registerTable(L, "native", nativeFns);
    lua_getglobal(L, "native");
    lua_pushstring(L, "BaritoneDLL 1.1");
    lua_setfield(L, -2, "version");
    lua_pop(L, 1);
    lua_register(L, "log", l_log);
    lua_register(L, "print", l_print);
    lua_register(L, "onEvent", l_onEvent);
    lua_register(L, "registerCommand", l_registerCommand);

    lua_sethook(L, timeoutHook, LUA_MASKCOUNT, 20000);

    // script: %LOCALAPPDATA%\Latite\Baritone\Baritone.lua overrides the built-in one
    std::string script;
    std::string chunkName = "=Baritone.lua";
    std::filesystem::path overridePath = std::filesystem::path { util::StrToWStr(dataDir()) } / "Baritone.lua";
    std::error_code ec;
    if (std::filesystem::exists(overridePath, ec) && readWholeFile(overridePath, script) && !script.empty()) {
        chunkName = "=Baritone.lua (override)";
        std::string shown = pathToUtf8(overridePath);
        Logger::Info("[Baritone] using script override {}", shown);
    } else {
        script.assign(reinterpret_cast<const char*>(kBaritoneScript), kBaritoneScriptSize);
    }

    lua_pushcfunction(L, traceback);
    int tb = lua_gettop(L);
    g_callStart = Clock::now();
    g_inCall = true;
    int rc = luaL_loadbuffer(L, script.data(), script.size(), chunkName.c_str());
    if (rc == LUA_OK) rc = lua_pcall(L, 0, 0, tb);
    g_inCall = false;
    if (rc != LUA_OK) {
        std::string err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "unknown error";
        reportLuaError("script failed to load", err);
        lua_close(L);
        L = nullptr;
        luaFailed = true;
        return false;
    }
    lua_pop(L, 1); // traceback
    luaFailed = false;
    return true;
}

void BaritoneModule::stopLua() {
    std::lock_guard lock { luaMutex };
    releaseAllInput();
    if (L) {
        lua_close(L);
        L = nullptr;
    }
}

// Calls a handler registered with onEvent(name, fn). Args must already be on
// the stack. Leaves `nresults` values on the stack on success.
bool BaritoneModule::callEvent(const char* name, int nargs, int nresults) {
    if (!L) return false;
    lua_getfield(L, LUA_REGISTRYINDEX, "BaritoneEvents");
    lua_getfield(L, -1, name);
    lua_remove(L, -2);
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1 + nargs);
        return false;
    }
    lua_insert(L, -(nargs + 1));
    lua_pushcfunction(L, traceback);
    lua_insert(L, -(nargs + 2));
    int tb = lua_gettop(L) - nargs - 1;
    g_callStart = Clock::now();
    g_inCall = true;
    int rc = lua_pcall(L, nargs, nresults, tb);
    g_inCall = false;
    if (rc != LUA_OK) {
        std::string err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "unknown error";
        lua_pop(L, 2); // error + traceback fn
        reportLuaError(name, err);
        return false;
    }
    lua_remove(L, tb);
    return true;
}

void BaritoneModule::onEnable() {
    if (!startLua()) return;
    std::lock_guard lock { luaMutex };
    lua_getglobal(L, "onEnable");
    if (lua_isfunction(L, -1)) {
        g_callStart = Clock::now();
        g_inCall = true;
        if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
            reportLuaError("onEnable", lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
            lua_pop(L, 1);
        }
        g_inCall = false;
    } else {
        lua_pop(L, 1);
    }
}

void BaritoneModule::onDisable() {
    std::lock_guard lock { luaMutex };
    if (L) {
        lua_getglobal(L, "onDisable");
        if (lua_isfunction(L, -1)) {
            g_callStart = Clock::now();
            g_inCall = true;
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) lua_pop(L, 1);
            g_inCall = false;
        } else {
            lua_pop(L, 1);
        }
    }
    releaseAllInput();
}

void BaritoneModule::releaseAllInput() {
    {
        std::lock_guard lock { stateMutex };
        move = MoveState {};
        lmbWanted = rmbWanted = false;
        pendingClicks[1] = pendingClicks[2] = 0;
        pendingSlot = -1;
        lines.clear();
        boxes.clear();
        statusVisible = false;
    }
    releaseMoveKeys();
    if (sentLmb || tapLeft) {
        sendMouse(MOUSEEVENTF_LEFTUP);
        sentLmb = tapLeft = false;
    }
    if (sentRmb || tapRight) {
        sendMouse(MOUSEEVENTF_RIGHTUP);
        sentRmb = tapRight = false;
    }
    if (heldSlotKey) {
        sendKey(heldSlotKey, false);
        heldSlotKey = 0;
    }
}

void BaritoneModule::releaseMoveKeys() {
    for (auto& vk : keysDown) {
        if (vk) {
            sendKey(vk, false);
            vk = 0;
        }
    }
}

// Real clicks and hotbar keys - only while Minecraft is focused and no menu is open
void BaritoneModule::applyMouseAndKeys() {
    bool canSend = isGameFocused() && isInHud();
    bool lmb, rmb;
    int clicks[3];
    int slot;
    unsigned short wantKeys[7] = {};
    {
        std::lock_guard lock { stateMutex };
        bool active = move.active;
        if (inputMode == InputMode::Keys && active && canSend) {
            const bool want[7] = { move.forward, move.back, move.left, move.right, move.jump, move.sneak, move.sprint };
            for (int i = 0; i < 7; i++) wantKeys[i] = want[i] ? moveKeys[i] : static_cast<unsigned short>(0);
        }
        lmb = lmbWanted && active;
        rmb = rmbWanted && active;
        clicks[1] = pendingClicks[1];
        clicks[2] = pendingClicks[2];
        slot = pendingSlot;
        pendingClicks[1] = pendingClicks[2] = 0;
        pendingSlot = -1;
        if (!active) clicks[1] = clicks[2] = 0;
    }
    if (!canSend) {
        lmb = rmb = false;
        clicks[1] = clicks[2] = 0;
        slot = -1;
    }
    // movement keys (keys input mode): press / release whatever changed
    for (int i = 0; i < 7; i++) {
        if (keysDown[i] == wantKeys[i]) continue;
        if (keysDown[i]) sendKey(keysDown[i], false);
        if (wantKeys[i]) sendKey(wantKeys[i], true);
        keysDown[i] = wantKeys[i];
    }
    // finish last frame's taps (each key/click is held for one frame)
    if (heldSlotKey) {
        sendKey(heldSlotKey, false);
        heldSlotKey = 0;
    }
    if (tapRight) {
        sendMouse(MOUSEEVENTF_RIGHTUP);
        tapRight = false;
        sentRmb = false;
    }
    if (tapLeft) {
        sendMouse(MOUSEEVENTF_LEFTUP);
        tapLeft = false;
        sentLmb = false;
    }
    if (slot >= 0) {
        heldSlotKey = static_cast<WORD>('1' + slot);
        sendKey(heldSlotKey, true);
    }
    if (clicks[2] > 0 && !sentRmb) {
        sendMouse(MOUSEEVENTF_RIGHTDOWN);
        tapRight = true;
        return; // release next frame
    }
    if (clicks[1] > 0 && !sentLmb) {
        sendMouse(MOUSEEVENTF_LEFTDOWN);
        tapLeft = true;
        return;
    }
    if (lmb != sentLmb) {
        sendMouse(lmb ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP);
        sentLmb = lmb;
    }
    if (rmb != sentRmb) {
        sendMouse(rmb ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP);
        sentRmb = rmb;
    }
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------
void BaritoneModule::onTick(Event&) {
    lastTickMs = static_cast<long long>(nowMs());
    if (!localPlayer()) return;
    std::lock_guard lock { luaMutex };
    if (!L && !luaFailed) startLua();
    if (!L) return;

    // dimension change
    std::string dim;
    {
        auto lp = localPlayer();
        std::shared_ptr<SDK::Dimension> d = lp->dimension;
        if (d) dim = d->dimensionName;
    }
    if (!lastDimension.empty() && dim != lastDimension) {
        g_blockNames.clear();
        callEvent("ChangeDimensionEvent", 0, 0);
    }
    lastDimension = dim;

    callEvent("TickEvent", 0, 0);
}

void BaritoneModule::onRenderLayer(Event&) {
    auto now = Clock::now();
    if (now - lastFrame < std::chrono::milliseconds(3)) return; // once per frame
    lastFrame = now;
    if (!localPlayer()) return;
    {
        std::lock_guard lock { luaMutex };
        if (!L && !luaFailed) startLua();
        if (!L) return;
        callEvent("SetupAndRenderEvent", 0, 0);
    }
    applyMouseAndKeys();
}

void BaritoneModule::onRenderLevel(Event& evG) {
    if (!std::get<BoolValue>(renderPath)) return;
    auto& ev = reinterpret_cast<RenderLevelEvent&>(evG);
    std::vector<Line> copy;
    std::vector<Box> boxCopy;
    {
        std::lock_guard lock { stateMutex };
        if (lines.empty() && boxes.empty()) return;
        copy = lines;
        boxCopy = boxes;
    }
    auto ci = client();
    if (!ci || !ci->levelRenderer || !localPlayer()) return;
    MCDrawUtil3D dc { ci->levelRenderer, ev.getScreenContext(), SDK::MaterialPtr::getSelectionOverlayMaterial() };

    // translucent faces (ghost blocks are tinted with the colour of the block that goes there)
    bool anyFill = false;
    for (auto const& b : boxCopy) {
        if (b.fill <= 0.f) continue;
        anyFill = true;
        d2d::Color c(b.r, b.g, b.b, b.fill);
        const float x1 = b.x1, y1 = b.y1, z1 = b.z1, x2 = b.x2, y2 = b.y2, z2 = b.z2;
        dc.fillQuad({ x1, y1, z1 }, { x2, y1, z1 }, { x2, y1, z2 }, { x1, y1, z2 }, c); // bottom
        dc.fillQuad({ x1, y2, z1 }, { x2, y2, z1 }, { x2, y2, z2 }, { x1, y2, z2 }, c); // top
        dc.fillQuad({ x1, y1, z1 }, { x2, y1, z1 }, { x2, y2, z1 }, { x1, y2, z1 }, c); // north
        dc.fillQuad({ x1, y1, z2 }, { x2, y1, z2 }, { x2, y2, z2 }, { x1, y2, z2 }, c); // south
        dc.fillQuad({ x1, y1, z1 }, { x1, y2, z1 }, { x1, y2, z2 }, { x1, y1, z2 }, c); // west
        dc.fillQuad({ x2, y1, z1 }, { x2, y2, z1 }, { x2, y2, z2 }, { x2, y1, z2 }, c); // east
    }
    if (anyFill) dc.flush();

    for (auto const& l : copy) {
        dc.drawLine({ l.x1, l.y1, l.z1 }, { l.x2, l.y2, l.z2 }, d2d::Color(l.r, l.g, l.b, l.a));
    }
    for (auto const& b : boxCopy) {
        if (b.a <= 0.f) continue;
        d2d::Color c(b.r, b.g, b.b, b.a);
        const float x1 = b.x1, y1 = b.y1, z1 = b.z1, x2 = b.x2, y2 = b.y2, z2 = b.z2;
        dc.drawLine({ x1, y1, z1 }, { x2, y1, z1 }, c);
        dc.drawLine({ x2, y1, z1 }, { x2, y1, z2 }, c);
        dc.drawLine({ x2, y1, z2 }, { x1, y1, z2 }, c);
        dc.drawLine({ x1, y1, z2 }, { x1, y1, z1 }, c);
        dc.drawLine({ x1, y2, z1 }, { x2, y2, z1 }, c);
        dc.drawLine({ x2, y2, z1 }, { x2, y2, z2 }, c);
        dc.drawLine({ x2, y2, z2 }, { x1, y2, z2 }, c);
        dc.drawLine({ x1, y2, z2 }, { x1, y2, z1 }, c);
        dc.drawLine({ x1, y1, z1 }, { x1, y2, z1 }, c);
        dc.drawLine({ x2, y1, z1 }, { x2, y2, z1 }, c);
        dc.drawLine({ x2, y1, z2 }, { x2, y2, z2 }, c);
        dc.drawLine({ x1, y1, z2 }, { x1, y2, z2 }, c);
    }
    dc.flush();
}

void BaritoneModule::onChat(Event& evG) {
    auto& ev = reinterpret_cast<ChatEvent&>(evG);
    std::string text = ev.getText();
    if (text.empty() || text[0] != '#') {
        // the script may use another prefix; let it decide below
    }

    if (text == "#reload") {
        ev.setCancelled(true);
        stopLua();
        if (startLua()) {
            chat("[Baritone] Script reloaded");
            onEnable();
        }
        return;
    }

    std::lock_guard lock { luaMutex };
    if (!L && !luaFailed) startLua();
    if (!L) {
        if (!text.empty() && text[0] == '#') {
            ev.setCancelled(true);
            chat("\xC2\xA7" "c[Baritone] The bot script failed to start - see %LOCALAPPDATA%\\Latite\\Logs. Type #reload to retry.");
        }
        return;
    }
    lua_pushlstring(L, text.data(), text.size());
    lua_pushstring(L, "");
    lua_pushinteger(L, 0);
    if (callEvent("ChatSendEvent", 3, 1)) {
        if (lua_toboolean(L, -1)) ev.setCancelled(true);
        lua_pop(L, 1);
    } else if (!text.empty() && text[0] == '#') {
        ev.setCancelled(true); // never leak commands to the server
    }
}

// The game's input update reads rawInputState into the player's movement.
// While the bot is driving, write what it wants both before the update (so
// it's used this tick) and after it (so the keyboard can't override it).
void BaritoneModule::onBeforeMove(Event& evG) {
    auto& ev = reinterpret_cast<BeforeMoveEvent&>(evG);
    writeMoveInput(ev.getMoveInputHandler(), true);
}

void BaritoneModule::onAfterMove(Event& evG) {
    auto& ev = reinterpret_cast<AfterMoveEvent&>(evG);
    lastMoveMs = static_cast<long long>(nowMs());
    writeMoveInput(ev.getMoveInputHandler(), false);
}

void BaritoneModule::writeMoveInput(SDK::MoveInputComponent* input, bool before) {
    if (!input) return;
    MoveState m;
    InputMode mode;
    {
        std::lock_guard lock { stateMutex };
        m = move;
        mode = inputMode;
    }
    if (mode != InputMode::Hook || !m.active || !isInHud()) {
        if (!before) lastJump = lastSneak = false;
        return;
    }
    auto& s = input->rawInputState;
    s.up = m.forward;
    s.down = m.back;
    s.left = m.left;
    s.right = m.right;
    s.sprintDown = m.sprint;

    s.jumpDown = m.jump;
    s.jumpInputCurrentlyDown = m.jump;
    s.jumpInputWasPressed = m.jump && !lastJump;
    s.jumpInputWasReleased = !m.jump && lastJump;

    s.sneakDown = m.sneak;
    s.sneakInputCurrentlyDown = m.sneak;
    s.sneakInputWasPressed = m.sneak && !lastSneak;
    s.sneakInputWasReleased = !m.sneak && lastSneak;

    if (!before) {
        lastJump = m.jump;
        lastSneak = m.sneak;
    }
}

void BaritoneModule::onKey(Event& evG) {
    auto& ev = reinterpret_cast<KeyUpdateEvent&>(evG);
    int key = std::get<KeyValue>(stopKey).value;
    if (key != 0 && ev.getKey() == key && ev.isDown() && !ev.inUI()) {
        panicCount++;
        std::lock_guard lock { stateMutex };
        move.active = false;
        lmbWanted = rmbWanted = false;
    }
}

void BaritoneModule::onLeaveGame(Event&) {
    std::lock_guard lock { luaMutex };
    if (L) callEvent("DisconnectEvent", 0, 0);
    releaseAllInput();
    g_blockNames.clear();
    lastDimension.clear();
}

std::wstringstream BaritoneModule::text(bool isDefault, bool inEditor) {
    std::wstringstream wss;
    std::lock_guard lock { stateMutex };
    if (inEditor && statusText.empty()) wss << L"Baritone: Going to 100, 64, -200";
    else wss << L"Baritone: " << statusText;
    return wss;
}

bool BaritoneModule::isActive() {
    if (!std::get<BoolValue>(showStatus)) return false;
    std::lock_guard lock { stateMutex };
    return statusVisible;
}
