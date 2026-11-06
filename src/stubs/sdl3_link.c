/* This file exists to force linking against SDL3 via pkg-config */
#include <SDL3/SDL.h>
/* Reference a symbol from SDL3 to ensure the linker pulls it in */
void* wizp_sdl3_link_symbol = (void*)SDL_Init;
