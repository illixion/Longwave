// SPIKE ONLY: synthetic producer and latency harness for the external frame
// source (open question 18). The tool is C++ in the shim
// (spike_frame_source_tool.cpp); this only hands it the command line.
import CStreamWin
import ucrt

exit(lw_spike_frame_source_tool(CommandLine.argc, CommandLine.unsafeArgv))
