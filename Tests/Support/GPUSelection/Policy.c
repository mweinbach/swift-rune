#include "../../../Sources/CRuneGPUSelection/include/RuneGPUSelection.h"
#include <assert.h>
#include <stdio.h>

static uint64_t make_dev(uint64_t major, uint64_t minor) {
    return ((major & 0xfffff000) << 32) | ((major & 0xfff) << 8) |
           ((minor & 0xffffff00) << 12) | (minor & 0xff);
}

int main(void) {
    uint32_t decoded_major, decoded_minor, pair[][2] = {{226,128},{226,1},{0x12345,0x6789a}};
    for (unsigned i = 0; i < 3; i++) {
        uint64_t d = make_dev(pair[i][0], pair[i][1]);
        assert(rune_gpu_dev_numbers(&d, 8, &decoded_major, &decoded_minor));
        assert(decoded_major == pair[i][0] && decoded_minor == pair[i][1]);
    }
    uint32_t d32 = (226u << 8) | 128u;
    assert(rune_gpu_dev_numbers(&d32, 4, &decoded_major, &decoded_minor) && decoded_major == 226 && decoded_minor == 128);
    assert(!rune_gpu_dev_numbers(&d32, 3, &decoded_major, &decoded_minor));
    char pci[13];
    assert(rune_gpu_pci_link("../../../0000:01:00.0", pci) && !strcmp(pci, "0000:01:00.0"));
    assert(rune_gpu_pci_link("../../../0000:C5:00.0", pci) && !strcmp(pci, "0000:c5:00.0"));
    assert(!rune_gpu_pci_link("../../../simple-framebuffer.0", pci) && !rune_gpu_pci_link("../../../fd4ab000.gpu", pci));
    struct RuneGPUAdapter gpu[] = {
        {"AMD Radeon Graphics", "0000:0f:00.0",0x1002,0x13c0,RuneGPUIntegrated,1,1},
        {"NVIDIA GeForce RTX 5070", "0000:01:00.0",0x10de,0x2c05,RuneGPUDiscrete,1,0},
        {"NVIDIA GeForce RTX 5070", "0000:01:00.0",0x10de,0x2c05,RuneGPUDiscrete,1,1},
        {"llvmpipe", "",0x1414,0x8c,RuneGPUCPU,1,1},
    };
    assert(rune_gpu_by_pci(gpu,4,"0000:01:00.0")==2 && rune_gpu_by_pci(gpu,4,"0000:0F:00.0")==0);
    assert(rune_gpu_by_pci(gpu,4,"0000:02:00.0")==-1 && rune_gpu_by_pci(gpu,4,"")==-1);
    gpu[1].usable=gpu[2].usable=0;
    assert(rune_gpu_by_pci(gpu,4,"0000:01:00.0")==-1 && rune_gpu_by_name(gpu,4,"nvidia")==-1 && rune_gpu_by_name(gpu,4,"RADEON")==0);
    assert(rune_gpu_shows("0000:01:00.0","0000:01:00.0") && !rune_gpu_shows("0000:01:00.0","0000:7c:00.0") && !rune_gpu_shows("0000:01:00.0",""));
    assert(rune_gpu_shows(NULL,"0000:7c:00.0") && rune_gpu_shows(NULL,""));
    struct RuneGPUAdapter powers[5]={{.power=RuneGPUCPU,.usable=1},{.power=RuneGPUDiscrete,.usable=1},{.power=RuneGPUOther,.usable=1},{.power=RuneGPUIntegrated,.usable=1},{.power=RuneGPUVirtual,.usable=1}};
    int ordered[]={3,1,4,2,0};
    for(int i=0;i<5;i++){assert(rune_gpu_by_power(powers,5,0)==ordered[i]);powers[ordered[i]].usable=0;}
    struct RuneGPUIDs ids;
    assert(rune_gpu_pci_ids("PCI\\VEN_10DE&DEV_2C05&SUBSYS_205E1458&REV_A1",&ids) && ids.vendor==0x10de && ids.device==0x2c05);
    assert(rune_gpu_pci_ids("pci\\ven_1002&dev_13c0&subsys_d0001458&rev_c9",&ids) && ids.vendor==0x1002 && ids.device==0x13c0);
    assert(!rune_gpu_pci_ids("SWD\\RemoteDisplayEnum",&ids) && !rune_gpu_pci_ids("PCI\\VEN_10DE",&ids) && !rune_gpu_pci_ids("",&ids));
    struct RuneGPUIDs discrete={0x10de,0x2c05}, integrated={0x1002,0x13c0}, intel={0x8086,0x56a0}, software={0x1414,0x8c};
    assert(rune_gpu_by_display(gpu,4,&discrete,1)==-1);
    gpu[1].usable=gpu[2].usable=1;
    assert(rune_gpu_by_display(gpu,4,&discrete,1)==1 && rune_gpu_by_display(gpu,4,&integrated,1)==0);
    struct RuneGPUIDs both[]={discrete,integrated}; assert(rune_gpu_by_display(gpu,4,both,2)==1);
    both[0]=integrated;both[1]=discrete;assert(rune_gpu_by_display(gpu,4,both,2)==0);
    both[0]=intel;assert(rune_gpu_by_display(gpu,4,both,2)==1);
    assert(rune_gpu_by_display(gpu,4,&software,1)==-1 && rune_gpu_by_display(gpu,4,&intel,1)==-1);
    puts("8 pinned gpu::pick_tests groups passed");
}
