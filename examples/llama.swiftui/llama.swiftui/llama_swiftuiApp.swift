import SwiftUI

@main
struct llama_swiftuiApp: App {
    // 1. 绑定代理适配器
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    
    var body: some Scene {
        WindowGroup {
//            ContentView()
            AdvancedChatView()
        }
    }
}

// 2. 定义 AppDelegate 来处理前台通知显示
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // 设置代理
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    
    // 让通知在前台也能显示 Banner
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // iOS 14+ 写法: 允许 Banner 和 声音
        completionHandler([.banner, .sound, .list])
    }
}
