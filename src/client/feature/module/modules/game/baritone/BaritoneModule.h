#pragma once
// Baritone for Bedrock - a Baritone-style pathfinding bot built into the DLL.
//
// The bot logic (pathfinder, processes, commands, settings) is Lua and runs in
// an embedded Lua 5.4 interpreter. This module is the bridge between that
// script and the game:
//   - reads the world, the player, entities and inventory through Latite's SDK
//   - drives the player with the game's own movement input (MoveInputComponent),
//     the player's rotation, and real mouse clicks / hotbar keys
//   - draws the path, goal and schematic ghost blocks with the game's renderer
//   - handles "#" chat commands locally (they are never sent to the server)
#include "client/feature/module/TextModule.h"
#include <atomic>
#include <mutex>
#include <string>
#include <vector>

struct lua_State;

class BaritoneModule : public TextModule {
public:
    BaritoneModule();
    ~BaritoneModule() override;

    void onEnable() override;
    void onDisable() override;

    static BaritoneModule* instance;

    // --- state shared with the Lua bindings (see BaritoneLua.cpp) ---
    struct MoveState {
        bool active = false;
        bool forward = false, back = false, left = false, right = false;
        bool jump = false, sneak = false, sprint = false;
    };

    struct Line {
        float x1, y1, z1, x2, y2, z2;
        float r, g, b, a;
    };

    std::mutex stateMutex; // guards the fields below
    MoveState move;
    bool lmbWanted = false;
    bool rmbWanted = false;
    int pendingClicks[3] = { 0, 0, 0 }; // index 1 = left, 2 = right
    int pendingSlot = -1;
    bool hasRotationTarget = false;
    float rotPitch = 0.f, rotYaw = 0.f;
    bool hasTurn = false;
    float turnX = 0.f, turnY = 0.f;
    std::vector<Line> lines;
    std::wstring statusText;
    bool statusVisible = false;

    std::atomic<int> panicCount { 0 };

    bool isGameFocused();
    bool isInHud();
    void chat(std::string const& msg);
    std::string const& dataDir();

private:
    void onTick(Event& ev);
    void onRenderLayer(Event& ev);
    void onRenderLevel(Event& ev);
    void onChat(Event& ev);
    void onAfterMove(Event& ev);
    void onKey(Event& ev);
    void onLeaveGame(Event& ev);

    bool startLua();
    void stopLua();
    bool callEvent(const char* name, int nargs, int nresults);
    void reportLuaError(std::string const& where, std::string const& err);
    void applyMouseAndKeys();
    void releaseAllInput();

    lua_State* L = nullptr;
    std::recursive_mutex luaMutex;
    bool luaFailed = false;
    std::chrono::steady_clock::time_point lastFrame {};
    std::chrono::steady_clock::time_point lastErrorTime {};
    std::string lastDimension;
    bool lastJump = false, lastSneak = false;
    bool sentLmb = false, sentRmb = false;
    bool tapLeft = false, tapRight = false;
    unsigned short heldSlotKey = 0;

    ValueType stopKey = KeyValue('X');
    ValueType showStatus = BoolValue(true);
    ValueType renderPath = BoolValue(true);

protected:
    std::wstringstream text(bool isDefault, bool inEditor) override;
    bool isActive() override;
};
