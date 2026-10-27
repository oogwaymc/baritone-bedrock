#pragma once
#include <cstdint>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "baritone/utils/BlockPos.h"

namespace sdk {
class LocalPlayer;
class BlockSource;
class Container;
}  // namespace sdk

// Sorts chests, barrels and shulker boxes: stacks of the same item are merged, then the slots
// are ordered (blocks, then tools/weapons/armor, then other items, each by name, bigger stacks
// first). Items are moved with the same server requests the inventory screen sends, one at a
// time, so the container has to be open: sorting starts when the player opens one with a right
// click (chestSortOnOpen), or with #sort, which opens the one the player looks at.
//
// Anything unexpected (container not found, a move refused) stops the sort with a message; it
// never guesses. Closing and opening the chest again starts over from what the server sent.
class ChestSorter {
public:
    void onFrame();  // every frame: notices a right click on a container
    void tick(sdk::LocalPlayer& player, sdk::BlockSource& region, uint64_t tick);
    void onItemStackResponse(int requestId, int result);  // the server's answer, from the response hook
    void requestSort();  // #sort
    void cancel();
    bool busy() const { return state_ != State::Idle; }

private:
    enum class State { Idle, WaitingForOpen, Sorting };
    enum class OpKind { Swap, Move, Merge };

    struct Slot {
        const void* item = nullptr;
        const void* block = nullptr;
        const void* userData = nullptr;
        std::string name;
        int count = 0;
        int maxDamage = 0;
        bool empty() const { return count == 0 || item == nullptr; }
    };
    struct Op {
        OpKind kind;
        int from, to, amount;  // amount: items moved (0 for a swap)
    };
    struct Pending {
        Op op;
        int requestId;
        uint64_t sentAt;
        Slot fromBefore, toBefore;
        int result = -1;  // -1: no answer yet, 0: accepted
    };

    static bool isSortable(std::string_view block);
    static int maxStack(const Slot& s);
    std::vector<Slot> read(sdk::Container& c, int size) const;
    std::optional<Op> nextOp(const std::vector<Slot>& slots) const;
    sdk::Container* resolve(sdk::LocalPlayer& player, sdk::BlockSource& region, int& size);
    void start(const baritone::BlockPos& pos, const std::string& block, int waitTicks, bool manual);
    void finish(const std::string& message, bool error);
    bool applyAccepted(sdk::Container& c, sdk::LocalPlayer& player);

    State state_ = State::Idle;
    baritone::BlockPos target_{};
    std::string targetBlock_;
    bool manual_ = false;
    int wait_ = 0;
    uint64_t tick_ = 0;
    uint64_t retryAt_ = 0;
    int moves_ = 0;
    bool acceptedAny_ = false;
    int openAttempts_ = 0;
    std::size_t nameIndex_ = 0;  // which container name the server knows this container by
    std::vector<uint8_t> names_;
    std::optional<Pending> pending_;
    int busyTicks_ = 0;  // ticks the request manager was busy with another request
    std::set<std::string> noMerge_;  // items the server refused to merge (different data)
    bool loggedContainer_ = false;
    bool unsupported_ = false;  // this game version's block actors don't match: stop trying
    bool reportedAutoFailure_ = false;

    // #sort: wait for the chat to close, then open the container the player looks at
    int manualDelay_ = -1;

    // right clicks seen during frames, used by the next tick
    std::mutex clickLock_;
    std::optional<baritone::BlockPos> clicked_;
    bool rightWasDown_ = false;
};
