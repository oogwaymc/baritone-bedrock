#include "sdk/Game.h"

#include <Windows.h>

#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <unordered_map>
#include <utility>

#include "memory/Signatures.h"

namespace sdk {

namespace {

struct ClientInterface {
    void* clientInterface;
    std::shared_ptr<ClientInstance> instance;
};
static_assert(sizeof(ClientInterface) == 0x18);

}  // namespace

ClientInstance* ClientInstance::get() {
    static ClientInstance* cached = nullptr;
    if (cached) return cached;
    if (!sigs::PlatformGameCore.address) return nullptr;  // signature not found (unsupported game version)

    void* winMain = *sigs::PlatformGameCore.as<void**>();
    if (!winMain) return nullptr;
    void* platform = mem::member<void*>(winMain, offsets::WinMain_platform);
    if (!platform) return nullptr;
    void* holder = mem::member<void*>(platform, offsets::Platform_gameHolder);
    if (!holder) return nullptr;
    void* game = mem::member<void*>(holder, offsets::GameHolder_minecraftGame);
    if (!game) return nullptr;

    const auto& clients = mem::member<std::map<uint8_t, ClientInterface>>(game, offsets::MinecraftGame_clientInstances);
    auto it = clients.find(0);
    if (it == clients.end()) return nullptr;
    cached = it->second.instance.get();
    return cached;
}

void gameFree(void* ptr) {
    if (!ptr) return;
    sigs::GameOperatorDelete.as<void(__fastcall*)(void*)>()(ptr);
}

void* gameAlloc(std::size_t size) {
    // operator delete reads the allocator from a global: mov rcx, [rip+global] at +0x15
    uintptr_t del = sigs::GameOperatorDelete.address;
    auto global = reinterpret_cast<void* const*>(del + 0x1C + *reinterpret_cast<const int32_t*>(del + 0x18));
    void* allocator = *global;
    return allocator ? mem::callVirtual<void*, std::size_t>(allocator, 1, size) : nullptr;
}

namespace {

// ItemStackRequestSlotInfo: FullContainerName {name, optional<uint> dynamicId}, slot, net id
void fillSlotInfo(uint8_t* info, uint8_t containerName, int slot, const ItemStack* stack) {
    std::memset(info, 0, 0x28);
    info[0x0] = containerName;
    info[0xC] = static_cast<uint8_t>(slot);
    std::memcpy(info + 0x10, reinterpret_cast<const uint8_t*>(stack) + offsets::ItemStack_netIdVariant, 0x18);
}

void fillSlotInfo(uint8_t* info, int slot, const ItemStack* stack) {
    fillSlotInfo(info, slot < 9 ? offsets::ContainerEnumName_Hotbar : offsets::ContainerEnumName_Inventory, slot, stack);
}

// A copy of an ItemStack in caller-provided storage (the game's copy: base copy, vtable, net id).
struct StackCopy {
    alignas(16) uint8_t bytes[offsets::ItemStack_size];
    explicit StackCopy(const ItemStack& src) {
        sigs::ItemStackBase_copy.as<void*(__fastcall*)(void*, const void*)>()(bytes, &src);
        std::memcpy(bytes, &src, sizeof(uintptr_t));  // ItemStack vtable
        std::memcpy(bytes + offsets::ItemStack_netIdVariant,
                    reinterpret_cast<const uint8_t*>(&src) + offsets::ItemStack_netIdVariant, 0x18);
    }
    ~StackCopy() { mem::callVirtual<void*, uint32_t>(bytes, 0, 0u); }  // destructor, no delete
    StackCopy(const StackCopy&) = delete;
    StackCopy& operator=(const StackCopy&) = delete;
    const ItemStack& get() const { return *reinterpret_cast<const ItemStack*>(bytes); }
    void setCount(int count) { bytes[0x22] = static_cast<uint8_t>(count); }  // ItemStackBase count (see ItemStack::count)
};

// Address range of Minecraft.Windows.exe in memory (vtables and code live there).
std::pair<uintptr_t, uintptr_t> gameModule() {
    static const std::pair<uintptr_t, uintptr_t> range = [] {
        auto base = reinterpret_cast<uintptr_t>(GetModuleHandleW(L"Minecraft.Windows.exe"));
        if (!base) return std::pair<uintptr_t, uintptr_t>{0, 0};
        auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        auto nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
        return std::pair<uintptr_t, uintptr_t>{base, base + nt->OptionalHeader.SizeOfImage};
    }();
    return range;
}

bool inGameModule(const void* p) {
    auto [lo, hi] = gameModule();
    auto v = reinterpret_cast<uintptr_t>(p);
    return lo && v >= lo && v < hi;
}

// The game's request for a transfer between two slots (see sendItemTransfer).
int sendTransferRequest(LocalPlayer& player, uint8_t srcName, int srcSlot, const ItemStack* src, uint8_t dstName,
                        int dstSlot, const ItemStack* dst, int amount) {
    void* manager = mem::member<void*>(&player, offsets::Player_itemStackNetManager);
    if (!mem::isReadable(manager, 0x70) || !mem::member<bool>(manager, offsets::ItemStackNetManager_enabled)) return 0;
    if (mem::member<void*>(manager, offsets::ItemStackNetManager_currentRequest)) return 0;  // one being built

    auto* action = static_cast<uint8_t*>(gameAlloc(offsets::ItemStackRequestTransfer_size));
    if (!action) return 0;
    std::memset(action, 0, offsets::ItemStackRequestTransfer_size);
    *reinterpret_cast<uintptr_t*>(action) = sigs::ItemStackRequestTransfer_vtable.address;
    action[0x10] = 1;
    if (amount > 0) {
        action[0x8] = 1;  // ItemStackRequestActionType::Place
        action[0x11] = 1;
        action[0x12] = static_cast<uint8_t>(amount);
    } else {
        action[0x8] = 2;  // ItemStackRequestActionType::Swap
    }
    fillSlotInfo(action + offsets::ItemStackRequestTransfer_src, srcName, srcSlot, src);
    fillSlotInfo(action + offsets::ItemStackRequestTransfer_dst, dstName, dstSlot, dst);

    sigs::ItemStackNet_beginRequest.as<void(__fastcall*)(void*, bool)>()(manager, false);
    // ItemStackRequestData: request id (int) at +8
    void* request = mem::member<void*>(manager, offsets::ItemStackNetManager_currentRequest);
    int id = request ? mem::member<int32_t>(request, 8) : 0;
    void* owned = action;  // std::unique_ptr passed by value: the callee keeps or deletes it
    sigs::ItemStackNet_addRequestAction.as<void(__fastcall*)(void*, void**)>()(manager, &owned);
    sigs::ItemStackNet_endRequest.as<void(__fastcall*)(void*)>()(manager);  // queued, sent this tick
    return id;
}

}  // namespace

int sendInventoryMove(LocalPlayer& player, int slotA, int slotB) {
    if (slotA < 0 || slotA >= 36 || slotB < 0 || slotB >= 36 || slotA == slotB) return 0;
    PlayerInventory* supplies = player.supplies();
    Inventory* inv = supplies ? supplies->inventory() : nullptr;
    const ItemStack* a = inv ? inv->getItem(slotA) : nullptr;
    const ItemStack* b = inv ? inv->getItem(slotB) : nullptr;
    if (!a || !b || a->empty()) return 0;
    void* manager = mem::member<void*>(&player, offsets::Player_itemStackNetManager);
    if (!mem::isReadable(manager, 0x70) || !mem::member<bool>(manager, offsets::ItemStackNetManager_enabled)) return 0;
    if (mem::member<void*>(manager, offsets::ItemStackNetManager_currentRequest)) return 0;  // one being built

    auto* action = static_cast<uint8_t*>(gameAlloc(offsets::ItemStackRequestTransfer_size));
    if (!action) return 0;
    std::memset(action, 0, offsets::ItemStackRequestTransfer_size);
    *reinterpret_cast<uintptr_t*>(action) = sigs::ItemStackRequestTransfer_vtable.address;
    action[0x10] = 1;
    if (b->empty()) {
        // the server refuses a swap with an empty slot: place the whole stack there instead
        action[0x8] = 1;  // ItemStackRequestActionType::Place
        action[0x11] = 1;
        action[0x12] = a->count();
    } else {
        action[0x8] = 2;  // ItemStackRequestActionType::Swap
    }
    fillSlotInfo(action + offsets::ItemStackRequestTransfer_src, slotA, a);
    fillSlotInfo(action + offsets::ItemStackRequestTransfer_dst, slotB, b);

    sigs::ItemStackNet_beginRequest.as<void(__fastcall*)(void*, bool)>()(manager, false);
    // ItemStackRequestData: request id (int) at +8
    void* request = mem::member<void*>(manager, offsets::ItemStackNetManager_currentRequest);
    int id = request ? mem::member<int32_t>(request, 8) : 0;
    void* owned = action;  // std::unique_ptr passed by value: the callee keeps or deletes it
    sigs::ItemStackNet_addRequestAction.as<void(__fastcall*)(void*, void**)>()(manager, &owned);
    sigs::ItemStackNet_endRequest.as<void(__fastcall*)(void*)>()(manager);  // queued, sent this tick
    return id;
}

bool applyInventoryMoveLocally(LocalPlayer& player, int slotA, int slotB) {
    if (slotA < 0 || slotA >= 36 || slotB < 0 || slotB >= 36 || slotA == slotB) return false;
    PlayerInventory* supplies = player.supplies();
    Inventory* inv = supplies ? supplies->inventory() : nullptr;
    const ItemStack* a = inv ? inv->getItem(slotA) : nullptr;
    const ItemStack* b = inv ? inv->getItem(slotB) : nullptr;
    if (!a || !b) return false;
    StackCopy copyA(*a), copyB(*b);
    inv->setItem(slotA, copyB.get());
    inv->setItem(slotB, copyA.get());
    return true;
}

Container* findContainerIn(const void* blockActor, const Inventory* playerInventory) {
    constexpr std::size_t kScanBytes = 0x600;  // block actors are a few hundred bytes
    if (!mem::isReadable(blockActor, 16) || !mem::isReadable(playerInventory, 16)) return nullptr;
    void** reference = mem::vtable(playerInventory);
    if (!inGameModule(reference) || !mem::isReadable(reference, offsets::Container_vt_count * sizeof(void*))) return nullptr;
    void** actorVtable = mem::vtable(blockActor);
    if (!inGameModule(actorVtable)) return nullptr;

    auto looksLikeContainer = [&](std::ptrdiff_t off) {
        auto at = reinterpret_cast<const uint8_t*>(blockActor) + off;
        if (!mem::isReadable(at, 16)) return false;
        void** vt = *reinterpret_cast<void** const*>(at);
        if (vt == reference || !inGameModule(vt)) return false;  // never the player's own inventory
        if (!mem::isReadable(vt, offsets::Container_vt_count * sizeof(void*))) return false;
        std::size_t same = 0;
        for (std::size_t i : offsets::Container_vt_inherited) same += vt[i] == reference[i];
        if (same + 3 < std::size(offsets::Container_vt_inherited)) return false;  // a few overrides at most
        return inGameModule(vt[offsets::Inventory_vt_getItem]) && inGameModule(vt[offsets::Inventory_vt_setItem]) &&
               inGameModule(vt[offsets::Container_vt_getContainerSize]);
    };
    // the offset only depends on the block actor's type (chest, barrel...): remember it
    static std::unordered_map<void**, std::ptrdiff_t> knownOffsets;
    if (auto it = knownOffsets.find(actorVtable); it != knownOffsets.end()) {
        if (looksLikeContainer(it->second)) {
            return reinterpret_cast<Container*>(reinterpret_cast<uintptr_t>(blockActor) + it->second);
        }
        knownOffsets.erase(it);
    }
    for (std::ptrdiff_t off = 8; off + 16 <= static_cast<std::ptrdiff_t>(kScanBytes); off += 8) {
        if (!looksLikeContainer(off)) continue;
        knownOffsets[actorVtable] = off;
        return reinterpret_cast<Container*>(reinterpret_cast<uintptr_t>(blockActor) + off);
    }
    return nullptr;
}

int sendItemTransfer(LocalPlayer& player, const SlotRef& src, const SlotRef& dst, int amount) {
    if (!src.stack || !dst.stack || src.stack->empty() || (src.slot == dst.slot && src.containerName == dst.containerName)) return 0;
    if (amount < 0 || amount > src.stack->count()) return 0;
    if (amount == 0 && dst.stack->empty()) return 0;  // the server refuses a swap with an empty slot
    return sendTransferRequest(player, src.containerName, src.slot, src.stack, dst.containerName, dst.slot, dst.stack,
                               amount);
}

bool applyContainerMoveLocally(Container& container, int from, int to, int amount, const ItemStack* empty) {
    const ItemStack* a = container.getItem(from);
    const ItemStack* b = container.getItem(to);
    if (!a || !b || from == to) return false;
    if (amount == 0 || b->empty()) {
        // swap, or a whole stack into an empty slot: the two stacks trade places
        StackCopy copyA(*a), copyB(*b);
        container.setItem(from, copyB.get());
        container.setItem(to, copyA.get());
        return true;
    }
    // merge `amount` items of `from` into the same item at `to`
    if (amount > a->count()) return false;
    StackCopy merged(*b);
    merged.setCount(b->count() + amount);
    if (amount == a->count()) {
        if (!empty || !empty->empty()) return false;
        StackCopy nothing(*empty);
        container.setItem(from, nothing.get());
    } else {
        StackCopy rest(*a);
        rest.setCount(a->count() - amount);
        container.setItem(from, rest.get());
    }
    container.setItem(to, merged.get());
    return true;
}

std::vector<Actor*> Level::actors() const {
    // The game builds the vector with its own allocator: read it, then free its buffer
    // with the game's operator delete.
    struct RawVector {
        Actor** first = nullptr;
        Actor** last = nullptr;
        Actor** end = nullptr;
    } raw;
    mem::callVirtual<RawVector*, RawVector*>(this, offsets::Level_vt_getRuntimeActorList, &raw);
    std::vector<Actor*> out(raw.first, raw.last);
    gameFree(raw.first);
    return out;
}

std::string Level::name() const {
    void* data = mem::member<std::shared_ptr<void>>(this, offsets::Level_levelData).get();
    if (!mem::isReadable(data, offsets::LevelData_levelName + 0x20)) return {};
    const auto& name = mem::member<std::string>(data, offsets::LevelData_levelName);
    if (name.size() > 256 || !mem::isReadable(name.data(), name.size() + 1)) return {};
    return name;
}

Vec4 rotationToQuaternion(float pitch, float yaw) {
    // Euler (pitch, yaw, roll = 0) to quaternion, in the component order the game uses.
    constexpr float kDegToRad = 3.14159265358979f / 180.f;
    float cx = std::cos(pitch * kDegToRad * 0.5f), sx = std::sin(pitch * kDegToRad * 0.5f);
    float cy = std::cos(yaw * kDegToRad * 0.5f), sy = std::sin(yaw * kDegToRad * 0.5f);
    return {-sx * sy, cx * cy, sx * cy, cx * sy};
}

void GuiData::displayClientMessage(const std::string& message) {
    using Fn = void(__fastcall*)(GuiData*, const std::string&, std::optional<std::string>, bool);
    // The optional is passed by value and destroyed by the game: keep it empty so no
    // memory allocated by our CRT is freed by the game's.
    sigs::GuiData_displayMessage.as<Fn>()(this, message, std::nullopt, false);
}

// ---- item durability and enchantments ----
// Pure lookups in the item's user data (a CompoundTag), the same calls the game makes to
// show the durability bar: no allocation, nothing written.
namespace {

struct TagView {
    const void* tag;
    uint8_t id() const { return mem::callVirtual<uint8_t>(tag, 5); }  // Tag::getId (vtable +0x28)
};

const void* compoundGet(const void* compound, std::string_view key) {
    using GetFn = const void*(__fastcall*)(const void* compound, const std::string_view* key);
    auto fn = reinterpret_cast<GetFn>(sigs::CompoundTag_get.address);
    if (!fn || !compound) return nullptr;
    return fn(compound, &key);
}

int shortOrByte(const void* tag) {
    if (!tag) return 0;
    uint8_t id = TagView{tag}.id();
    if (id == 1) return mem::member<int8_t>(tag, 8);   // ByteTag
    if (id == 2) return mem::member<int16_t>(tag, 8);  // ShortTag
    if (id == 3) return mem::member<int32_t>(tag, 8);  // IntTag
    return 0;
}

}  // namespace

int ItemStack::damage() const {
    using DamageFn = int16_t(__fastcall*)(const ItemStack*);
    auto fn = reinterpret_cast<DamageFn>(sigs::ItemStackBase_getDamageValue.address);
    return fn && !empty() ? fn(this) : 0;
}

int ItemStack::maxDamage() const {
    const Item* it = item();
    return it ? mem::member<uint16_t>(it, offsets::Item_maxDamage) : 0;
}

std::vector<std::pair<int, int>> ItemStack::enchants() const {
    std::vector<std::pair<int, int>> out;
    if (empty()) return out;
    const void* userData = mem::member<const void*>(this, offsets::ItemStack_userData);
    const void* list = compoundGet(userData, "ench");
    if (!list || TagView{list}.id() != 9) return out;  // ListTag
    // ListTag: std::vector<std::unique_ptr<Tag>> at +8
    auto begin = mem::member<const void* const*>(list, 0x8);
    auto end = mem::member<const void* const*>(list, 0x10);
    if (!begin || end < begin || end - begin > 64) return out;
    for (auto it = begin; it != end; ++it) {
        const void* entry = *it;
        if (!entry || TagView{entry}.id() != 10) continue;  // CompoundTag
        int id = shortOrByte(compoundGet(entry, "id"));
        int lvl = shortOrByte(compoundGet(entry, "lvl"));
        out.emplace_back(id, lvl);
    }
    return out;
}

}  // namespace sdk

