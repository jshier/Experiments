import Foundation

// Line-buffer stdout so output survives a crash.
setvbuf(stdout, nil, _IOLBF, 0)

runAllExperiments()
