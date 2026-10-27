#include "core/ChestSorter.h"

#include <Windows.h>

#include <algorithm>
#include <cmath>
#include <format>
#include <utility>

#include "baritone/Settings.h"
#include "core/Bot.h"
#include "core/Chat.h"
#include "core/Log.h"
#include "hooks/GameHooks.h"
#include "sdk/Game.h"

using baritone::BlockPos;

namespace {

constexpr int kMaxOpenAttempts = 6;     // first move refused: the container is probably not open yet
constexpr int kTicksBetweenAttempts = 5;
constexpr int kResponseTimeoutTicks = 60;
constexpr double kMaxDistance = 8.0;    // walking away from the container stops the sort
constexpr int kMaxMoves = 300;          // a 54 slot chest needs far fewer: something is wrong

bool gameWindowInForeground() {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return pid == GetCurrentProcessId();
}

std::string blockNameAt(sdk::BlockSource& region, const BlockPos& p) {
    const sdk::Block* b = region.getBlock(sdk::BlockPos{p.x, p.y, p.z});
    if (!mem::isReadable(b, offsets::Block_legacy + 8)) return {};
    const sdk::BlockLegacy* legacy = b->legacy();
    if (!mem::isReadable(legacy, offsets::BlockLegacy_namespacedId + 0x30)) return {};
    return legacy->name();
}

bool isChest(std::string_view block) {
    return block == "minecraft:chest" || block == "minecraft:trapped_chest" || block.find("copper_chest") != std::string_view::npos;
}

// Display order: blocks, then things with durability (tools, weapons, armor), then other items.
int category(const void* block, int maxDamage) {
    if (block) return 0;
    if (maxDamage > 0) return 1;
    return 2;
}

}  // namespace

// ---- what can be sorted ---------------------------------------------------------------

bool ChestSorter::isSortable(std::string_view block) {
    return isChest(block) || block == "minecraft:barrel" || block.ends_with("shulker_box");
}

// Most items stack to 64. The server refuses a merge over the real limit, and that item is then
// left unmerged (noMerge_), so a wrong guess here costs nothing.
int ChestSorter::maxStack(const Slot& s) {
    if (s.maxDamage > 0) return 1;
    std::string_view n = s.name;
    if (n.starts_with("minecraft:")) n.remove_prefix(10);
    static constexpr std::string_view sixteen[] = {"ender_pearl", "snowball", "egg", "brown_egg", "blue_egg", "bucket",
                                                   "honey_bottle", "armor_stand", "written_book"};
    static constexpr std::string_view one[] = {"cake", "saddle", "totem_of_undying", "enchanted_book", "writable_book",
                                               "potion", "splash_potion", "lingering_potion", "mushroom_stew",
                                               "rabbit_stew", "beetroot_soup", "suspicious_stew", "minecart",
                                               "chest_minecart", "hopper_minecart", "tnt_minecart",
                                               "command_block_minecart", "spyglass", "bundle", "goat_horn",
                                               "knowledge_book", "debug_stick", "ominous_bottle", "filled_map"};
    if (std::ranges::find(sixteen, n) != std::end(sixteen)) return 16;
    if (std::ranges::find(one, n) != std::end(one)) return 1;
    if (n.ends_with("_sign") || n.ends_with("_banner")) return 16;
    if ((n.ends_with("_bucket") && n != "bucket") || n.ends_with("_boat") || n.ends_with("_raft") || n.ends_with("_bed") ||
        n.ends_with("shulker_box") || n.starts_with("music_disc") || n.ends_with("horse_armor") || n.ends_with("_bundle")) {
        return 1;
    }
    return 64;
}

std::vector<ChestSorter::Slot> ChestSorter::read(sdk::Container& c, int size) const {
    std::vector<Slot> out(static_cast<std::size_t>(size));
    for (int i = 0; i < size; ++i) {
        const sdk::ItemStack* stack = c.getItem(i);
        if (!mem::isReadable(stack, 0x30) || stack->empty()) continue;
        const sdk::Item* item = stack->item();
        if (!mem::isReadable(item, offsets::Item_namespacedId + 0x30)) continue;
        Slot& s = out[static_cast<std::size_t>(i)];
        s.item = item;
        s.block = stack->block();
        s.userData = stack->userData();
        s.name = item->name();
        s.count = stack->count();
        s.maxDamage = stack->maxDamage();
    }
    return out;
}

// The next move, worked out again from what the container holds now (never from a plan made
// earlier, so a refused or late move can't throw the rest off).
std::optional<ChestSorter::Op> ChestSorter::nextOp(const std::vector<Slot>& s) const {
    int n = static_cast<int>(s.size());
    // 1. top up partial stacks with the same item from later slots (plain items only: anything
    //    with extra data, like a name or enchantments, is never merged)
    for (int i = 0; i < n; ++i) {
        const Slot& a = s[i];
        if (a.empty() || a.userData || a.maxDamage > 0 || noMerge_.contains(a.name)) continue;
        int max = maxStack(a);
        if (a.count >= max) continue;
        for (int j = i + 1; j < n; ++j) {
            const Slot& b = s[j];
            if (b.empty() || b.item != a.item || b.block != a.block || b.userData) continue;
            return Op{OpKind::Merge, j, i, std::min(b.count, max - a.count)};
        }
    }
    // 2. order the slots (selection sort: each move puts the right stack in the first unsorted slot)
    auto before = [](const Slot& a, const Slot& b) {
        if (a.empty() || b.empty()) return !a.empty() && b.empty();  // empty slots last
        int ca = category(a.block, a.maxDamage), cb = category(b.block, b.maxDamage);
        if (ca != cb) return ca < cb;
        if (a.name != b.name) return a.name < b.name;
        if (a.count != b.count) return a.count > b.count;  // full stacks first
        return !a.userData && b.userData;
    };
    for (int i = 0; i < n; ++i) {
        int best = i;
        for (int j = i + 1; j < n; ++j)
            if (before(s[j], s[best])) best = j;
        if (best == i) continue;
        if (s[i].empty()) return Op{OpKind::Move, best, i, s[best].count};
        return Op{OpKind::Swap, best, i, 0};
    }
    return std::nullopt;
}

// ---- finding the container -------------------------------------------------------------

sdk::Container* ChestSorter::resolve(sdk::LocalPlayer& player, sdk::BlockSource& region, int& size) {
    sdk::PlayerInventory* supplies = player.supplies();
    const sdk::Inventory* inventory = mem::isReadable(supplies, 0xC0) ? supplies->inventory() : nullptr;
    auto find = [&](const BlockPos& p, int& slots) -> sdk::Container* {
        const void* actor = region.getBlockEntity(sdk::BlockPos{p.x, p.y, p.z});
        if (!actor) return nullptr;
        sdk::Container* c = sdk::findContainerIn(actor, inventory);
        if (!c) {
            logger::warn("Chest sorter: no container found in the block actor at {} ({})", p, actor);
            return nullptr;
        }
        slots = c->size();
        if (!loggedContainer_) {
            logger::info("Chest sorter: {} at {}: block actor {}, container +0x{:X}, type {}, {} slots", targetBlock_, p,
                         actor, reinterpret_cast<uintptr_t>(c) - reinterpret_cast<uintptr_t>(actor),
                         static_cast<int>(c->type()), slots);
            loggedContainer_ = true;
        }
        if (slots != 27 && slots != 54) {
            logger::warn("Chest sorter: unexpected container size {} at {}", slots, p);
            return nullptr;
        }
        return c;
    };
    sdk::Container* c = find(target_, size);
    if (c && size == 27 && isChest(targetBlock_)) {
        // half of a double chest: the 54 slots the screen shows may be the other half's
        static constexpr int sides[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
        for (const auto& d : sides) {
            BlockPos other = target_.offset(d[0], 0, d[1]);
            if (blockNameAt(region, other) != targetBlock_) continue;
            int otherSize = 0;
            if (sdk::Container* pair = find(other, otherSize); pair && otherSize == 54) {
                size = otherSize;
                return pair;
            }
        }
    }
    return c;
}

// ---- state machine -----------------------------------------------------------------------

void ChestSorter::requestSort() {
    manualDelay_ = 5;  // the chat screen closes first
}

void ChestSorter::cancel() {
    state_ = State::Idle;
    pending_.reset();
    manualDelay_ = -1;
    std::lock_guard lock(clickLock_);
    clicked_.reset();
}

void ChestSorter::start(const BlockPos& pos, const std::string& block, int waitTicks, bool manual) {
    state_ = State::WaitingForOpen;
    target_ = pos;
    targetBlock_ = block;
    manual_ = manual;
    wait_ = waitTicks;
    retryAt_ = 0;
    moves_ = 0;
    acceptedAny_ = false;
    openAttempts_ = 0;
    nameIndex_ = 0;
    busyTicks_ = 0;
    pending_.reset();
    noMerge_.clear();
    loggedContainer_ = false;
    // the name the screen's slots go by (PocketMine's table): chests are "level entity"
    // containers, barrels and shulker boxes have their own; the level entity name is tried too
    if (block == "minecraft:barrel") names_ = {offsets::ContainerEnumName_Barrel, offsets::ContainerEnumName_LevelEntity};
    else if (block.ends_with("shulker_box")) names_ = {offsets::ContainerEnumName_ShulkerBox, offsets::ContainerEnumName_LevelEntity};
    else names_ = {offsets::ContainerEnumName_LevelEntity};
}

void ChestSorter::finish(const std::string& message, bool error) {
    if (!message.empty()) {
        logger::info("Chest sorter: {}", message);
        // automatic sorts stay quiet about failures after the first one this session
        bool say = !error || manual_ || !reportedAutoFailure_;
        if (error && !manual_) reportedAutoFailure_ = true;
        if (say) {
            if (error) chat::error("Chest sorter: " + message);
            else chat::info(message);
        }
    }
    state_ = State::Idle;
    pending_.reset();
}

void ChestSorter::onFrame() {
    bool down = (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
    bool pressed = down && !rightWasDown_;
    rightWasDown_ = down;
    if (!pressed || !baritone::Settings::get().chestSortOnOpen || unsupported_) return;
    auto* client = sdk::ClientInstance::get();
    if (!client || !client->minecraftGame() || !client->localPlayer()) return;
    // only clicks in the world: with a screen open (the chest's own), the cursor isn't grabbed
    if (!gameWindowInForeground() || !client->cursorGrabbedFlag()) return;
    platform::GamePlayerContext& player = Bot::get().player();
    if (!player.valid()) return;
    sdk::Level* level = player.level();
    const sdk::HitResult* hit = level ? level->hitResult() : nullptr;
    if (!mem::isReadable(hit, sizeof(sdk::HitResult)) || hit->type != 0) return;
    std::lock_guard lock(clickLock_);
    clicked_ = BlockPos{hit->block.x, hit->block.y, hit->block.z};
}

void ChestSorter::onItemStackResponse(int requestId, int result) {
    if (pending_ && pending_->requestId == requestId) pending_->result = result;
}

void ChestSorter::tick(sdk::LocalPlayer& player, sdk::BlockSource& region, uint64_t tick) {
    tick_ = tick;
    std::optional<BlockPos> clicked;
    {
        std::lock_guard lock(clickLock_);
        clicked = std::exchange(clicked_, std::nullopt);
    }
    // sneaking: the click placed a block instead of opening the container
    if (clicked && state_ == State::Idle && baritone::Settings::get().chestSortOnOpen && !unsupported_ &&
        !Bot::get().player().isSneaking()) {
        std::string block = blockNameAt(region, *clicked);
        if (isSortable(block)) start(*clicked, block, 4, false);
    }
    if (manualDelay_ >= 0 && --manualDelay_ < 0) {
        if (unsupported_) {
            chat::error("Chest sorter: can't read chests on this game version (see log.txt)");
        } else {
            sdk::Level* level = Bot::get().player().level();
            const sdk::HitResult* hit = level ? level->hitResult() : nullptr;
            std::string block;
            BlockPos pos{};
            if (mem::isReadable(hit, sizeof(sdk::HitResult)) && hit->type == 0) {
                pos = {hit->block.x, hit->block.y, hit->block.z};
                baritone::Vec3d eye = Bot::get().player().eyePosition();
                double dx = hit->pos.x - eye.x, dy = hit->pos.y - eye.y, dz = hit->pos.z - eye.z;
                double reach = baritone::Settings::get().blockReachDistance;
                if (dx * dx + dy * dy + dz * dz <= reach * reach) block = blockNameAt(region, pos);
            }
            if (!isSortable(block)) {
                chat::error("Look at a chest, barrel or shulker box within reach, then type #sort");
            } else {
                gamehooks::requestClick(2);  // opens it, like the player's right click
                start(pos, block, 8, true);
            }
        }
    }
    if (state_ == State::Idle) return;

    sdk::Vec3 feet = player.feet();
    double fx = feet.x - (target_.x + 0.5), fy = feet.y - target_.y, fz = feet.z - (target_.z + 0.5);
    if (fx * fx + fy * fy + fz * fz > kMaxDistance * kMaxDistance) {
        finish(manual_ ? "stopped: you moved away from the container" : "", true);
        return;
    }
    if (state_ == State::WaitingForOpen) {
        if (--wait_ > 0) return;
        state_ = State::Sorting;
    }

    int size = 0;
    sdk::Container* c = resolve(player, region, size);
    if (!c) {
        if (!isSortable(blockNameAt(region, target_))) {
            finish(manual_ ? "the container is gone" : "", true);
            return;
        }
        unsupported_ = true;  // the block is there but its contents can't be found: don't retry every chest
        finish("can't read chests on this game version, so it's turned off until the game restarts (details in log.txt)", true);
        return;
    }

    if (pending_) {
        Pending& p = *pending_;
        if (p.result < 0) {
            if (tick_ - p.sentAt > kResponseTimeoutTicks) finish("no answer from the game, stopped", true);
            return;
        }
        if (p.result == 0) {
            if (!applyAccepted(*c, player)) {
                finish("the container changed while sorting, stopped. Open it again to finish", true);
                return;
            }
            ++moves_;
            acceptedAny_ = true;
            pending_.reset();
            return;  // the next move from the updated contents, next tick
        }
        int result = p.result;
        OpKind kind = p.op.kind;
        std::string item = p.fromBefore.name;
        pending_.reset();
        if (!acceptedAny_) {
            // usually the container isn't open on the server yet; or it goes by another name.
            // A refused merge may also just be a wrong stack size guess: don't try that one again
            if (kind == OpKind::Merge) noMerge_.insert(item);
            if (++openAttempts_ < kMaxOpenAttempts) {
                nameIndex_ = (nameIndex_ + 1) % names_.size();
                retryAt_ = tick_ + kTicksBetweenAttempts;
                return;
            }
            finish(std::format("the game refused to move items (result {}). Is the container open?", result), true);
            return;
        }
        if (kind == OpKind::Merge) {
            noMerge_.insert(item);  // different data, or a smaller stack limit than guessed
            return;
        }
        finish(std::format("the game refused a move (result {}), stopped. Open the container again to finish", result), true);
        return;
    }
    if (tick_ < retryAt_) return;
    if (Bot::get().player().inventoryMovePending()) return;  // the bot's own inventory move first
    if (acceptedAny_) {
        // the player closed the container (back in the world, the cursor is grabbed again)
        auto* client = sdk::ClientInstance::get();
        if (client && gameWindowInForeground() && client->cursorGrabbedFlag()) {
            finish(manual_ ? std::format("stopped: the container was closed ({} moves done)", moves_) : "", true);
            return;
        }
    }
    if (moves_ >= kMaxMoves) {
        finish("stopped after too many moves", true);
        return;
    }

    std::vector<Slot> slots = read(*c, size);
    std::optional<Op> op = nextOp(slots);
    if (!op) {
        std::string what = targetBlock_.substr(targetBlock_.find(':') + 1);
        std::ranges::replace(what, '_', ' ');
        if (moves_ > 0) finish(std::format("Sorted {} ({} moves)", what, moves_), false);
        else finish(manual_ ? "Already sorted" : "", false);
        return;
    }
    uint8_t name = names_[nameIndex_];
    sdk::SlotRef src{name, op->from, c->getItem(op->from)};
    sdk::SlotRef dst{name, op->to, c->getItem(op->to)};
    int id = sdk::sendItemTransfer(player, src, dst, op->kind == OpKind::Swap ? 0 : op->amount);
    if (!id) {
        if (++busyTicks_ > 40) finish("the game's item requests stayed busy, stopped", true);
        return;
    }
    busyTicks_ = 0;
    logger::debug("Chest sorter: {} {} -> {} ({} x{}), request {}",
                  op->kind == OpKind::Swap ? "swap" : op->kind == OpKind::Move ? "move" : "merge", op->from, op->to,
                  slots[static_cast<std::size_t>(op->from)].name, op->amount, id);
    pending_ = Pending{*op, id, tick_, slots[static_cast<std::size_t>(op->from)], slots[static_cast<std::size_t>(op->to)]};
}

// The server accepted the pending move: show it on the client too (the game doesn't for
// requests it didn't make itself), unless it already does.
bool ChestSorter::applyAccepted(sdk::Container& c, sdk::LocalPlayer& player) {
    const Pending& p = *pending_;
    auto describe = [](sdk::Container& container, int slot) {
        const sdk::ItemStack* stack = container.getItem(slot);
        Slot s;
        if (mem::isReadable(stack, 0x30) && !stack->empty()) {
            s.item = stack->item();
            s.count = stack->count();
        }
        return s;
    };
    auto same = [](const Slot& a, const Slot& b) {
        if (a.empty() || b.empty()) return a.empty() && b.empty();
        return a.item == b.item && a.count == b.count;
    };
    Slot expectFrom, expectTo;
    switch (p.op.kind) {
        case OpKind::Swap:
            expectFrom = p.toBefore;
            expectTo = p.fromBefore;
            break;
        case OpKind::Move:
            expectTo = p.fromBefore;
            break;
        case OpKind::Merge:
            expectTo = p.toBefore;
            expectTo.count += p.op.amount;
            expectFrom = p.fromBefore;
            expectFrom.count -= p.op.amount;
            if (expectFrom.count <= 0) expectFrom = Slot{};
            break;
    }
    Slot nowFrom = describe(c, p.op.from), nowTo = describe(c, p.op.to);
    if (same(nowFrom, expectFrom) && same(nowTo, expectTo)) return true;  // already shown
    if (!same(nowFrom, p.fromBefore) || !same(nowTo, p.toBefore)) return false;  // something else moved them
    // a whole stack merged away leaves an empty slot: copy any empty stack into it
    const sdk::ItemStack* empty = nullptr;
    if (p.op.kind == OpKind::Merge && p.op.amount == p.fromBefore.count) {
        int size = c.size();
        for (int i = 0; i < size && !empty; ++i) {
            const sdk::ItemStack* s = c.getItem(i);
            if (i != p.op.from && mem::isReadable(s, 0x30) && s->empty()) empty = s;
        }
        sdk::PlayerInventory* supplies = player.supplies();
        sdk::Inventory* inv = mem::isReadable(supplies, 0xC0) ? supplies->inventory() : nullptr;
        for (int i = 0; i < 36 && !empty && inv; ++i) {
            const sdk::ItemStack* s = inv->getItem(i);
            if (mem::isReadable(s, 0x30) && s->empty()) empty = s;
        }
        if (!empty) return false;
    }
    return sdk::applyContainerMoveLocally(c, p.op.from, p.op.to, p.op.kind == OpKind::Swap ? 0 : p.op.amount, empty);
}
