#ifdef _WIN32
#include <windows.h>

// Adjust the top of an AdjustWindowRectExForDpi result for an installed custom caption.
void rune_custom_frame_adjust(HWND hwnd, RECT *rect, UINT dpi);
BOOL rune_custom_frame_installed(HWND hwnd);
#endif
