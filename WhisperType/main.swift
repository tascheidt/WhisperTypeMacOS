import Cocoa

// Create the Application instance (the shared instance)
let app = NSApplication.shared

// Create an instance of your AppDelegate
let delegate = AppDelegate()

// Assign the delegate to the application instance
// This is crucial for the application lifecycle methods (like applicationDidFinishLaunching) to be called.
app.delegate = delegate

// Start the application's main run loop.
// This function does not return until the application terminates.
// It handles processing events, calling delegate methods, etc.
// This replaces the automatic run loop start managed by the storyboard or @main.
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)

