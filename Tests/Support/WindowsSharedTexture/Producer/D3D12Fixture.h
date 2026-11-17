#pragma once

#include <d3d12.h>

// D3D12-created producer slots start in COMMON. The copy queue returns them to COMMON before publication.
static ComPtr<ID3D12Resource> makeImage12(ID3D12Device *device, const std::wstring &name,
                                          DXGI_FORMAT format, Handle &handle) {
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    heap.CreationNodeMask = heap.VisibleNodeMask = 1;
    D3D12_RESOURCE_DESC desc{};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = 4;
    desc.Height = 2;
    desc.DepthOrArraySize = desc.MipLevels = desc.SampleDesc.Count = 1;
    desc.Format = format;
    desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET | D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS;
    ComPtr<ID3D12Resource> texture;
    check(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_SHARED, &desc,
                                          D3D12_RESOURCE_STATE_COMMON, nullptr, IID_PPV_ARGS(&texture)),
          "D3D12 CreateCommittedResource");
    check(device->CreateSharedHandle(texture.Get(), nullptr, GENERIC_ALL, name.c_str(), &handle.value),
          "D3D12 CreateSharedHandle(texture)");
    return texture;
}

static void writeImage12(ID3D12Device *device, ID3D12Resource *texture, const UINT *pixels) {
    D3D12_HEAP_PROPERTIES uploadHeap{};
    uploadHeap.Type = D3D12_HEAP_TYPE_UPLOAD;
    uploadHeap.CreationNodeMask = uploadHeap.VisibleNodeMask = 1;
    D3D12_RESOURCE_DESC desc{};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = 2 * D3D12_TEXTURE_DATA_PITCH_ALIGNMENT;
    desc.Height = desc.DepthOrArraySize = desc.MipLevels = desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ComPtr<ID3D12Resource> upload;
    check(device->CreateCommittedResource(&uploadHeap, D3D12_HEAP_FLAG_NONE, &desc, D3D12_RESOURCE_STATE_GENERIC_READ,
                                          nullptr, IID_PPV_ARGS(&upload)), "D3D12 allocate upload");
    uint8_t *bytes = nullptr;
    D3D12_RANGE noRead{};
    check(upload->Map(0, &noRead, reinterpret_cast<void **>(&bytes)), "D3D12 map upload");
    std::memcpy(bytes, pixels, 16);
    std::memcpy(bytes + D3D12_TEXTURE_DATA_PITCH_ALIGNMENT, pixels + 4, 16);
    upload->Unmap(0, nullptr);
    D3D12_COMMAND_QUEUE_DESC queueDesc{};
    queueDesc.Type = D3D12_COMMAND_LIST_TYPE_COPY;
    ComPtr<ID3D12CommandQueue> queue;
    check(device->CreateCommandQueue(&queueDesc, IID_PPV_ARGS(&queue)), "D3D12 create copy queue");
    ComPtr<ID3D12CommandAllocator> allocator;
    check(device->CreateCommandAllocator(queueDesc.Type, IID_PPV_ARGS(&allocator)), "D3D12 allocate command list");
    ComPtr<ID3D12GraphicsCommandList> list;
    check(device->CreateCommandList(0, queueDesc.Type, allocator.Get(), nullptr, IID_PPV_ARGS(&list)), "D3D12 command list");
    D3D12_TEXTURE_COPY_LOCATION src{};
    src.pResource = upload.Get();
    src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src.PlacedFootprint.Footprint = {DXGI_FORMAT_B8G8R8A8_UNORM, 4, 2, 1, D3D12_TEXTURE_DATA_PITCH_ALIGNMENT};
    D3D12_TEXTURE_COPY_LOCATION dst{};
    dst.pResource = texture;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    list->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    check(list->Close(), "D3D12 close copy list");
    ID3D12CommandList *lists[] = {list.Get()};
    queue->ExecuteCommandLists(1, lists);
    ComPtr<ID3D12Fence> done;
    check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&done)), "D3D12 completion fence");
    check(queue->Signal(done.Get(), 1), "D3D12 submit completion");
    Handle event;
    event.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!event.value) std::exit(1);
    check(done->SetEventOnCompletion(1, event.value), "D3D12 await update");
    if (WaitForSingleObject(event.value, 5000) != WAIT_OBJECT_0) std::exit(1);
}
