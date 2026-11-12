// 极小的 no-op 程序：用于替代 RustDesk 每帧执行的
//   cmd /C tasklist | findstr consent.exe
// 只做一件事：立刻退出（退出码 0，无输出）。
// 编译：cl /c /O1 /GS- nop.c && link /SUBSYSTEM:WINDOWS /ENTRY:nopEntry /NODEFAULTLIB nop.obj kernel32.lib /OUT:rdnop.exe
#include <windows.h>

void WINAPI nopEntry(void) { ExitProcess(0); }
