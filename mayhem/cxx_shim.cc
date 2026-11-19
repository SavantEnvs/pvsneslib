#ifndef TOOL_ARGV
#define TOOL_ARGV char **
#endif
int tool_main(int, TOOL_ARGV);
extern "C" int tool_main_c(int argc, char **argv) { return tool_main(argc, (TOOL_ARGV)argv); }
