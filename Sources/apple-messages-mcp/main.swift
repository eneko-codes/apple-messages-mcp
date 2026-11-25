import Foundation
import MessagesMCPCore

// Launcher only. Everything testable lives in MessagesMCPCore, which the test target
// imports; an executable target cannot be imported.
await MessagesMCPServer.run()
