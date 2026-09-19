// Switcher 虚拟摄像头 —— CMIO Camera Extension 的入口（W3-C，设计方案 §8 虚拟摄像头行）。
// 系统扩展进程由 sysextd 启动；这里建 provider 并进 run loop。设备、流的实现在 CameraExtensionProvider.swift。
import CoreMediaIO
import Foundation

let providerSource = CameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
