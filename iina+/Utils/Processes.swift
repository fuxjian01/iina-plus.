//
//  YouGet.swift
//  iina+
//
//  Created by xjbeta on 2018/7/5.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Foundation
import Marshal
import SwiftHTTP
import PromiseKit

class Processes: NSObject {
    
    static let shared = Processes()
    let videoGet = VideoGet()
    var decodeTask: Process?
    var videoGetTasks: [(Promise<YouGetJSON>, cancel: () -> Void)] = []
    
    fileprivate override init() {
    }
    
    func which(_ str: String) -> [String] {
        // which you-get
        // command -v you-get
        // type -P you-get
        
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launchPath = "/bin/bash"
        task.arguments  = ["-l", "-c", "which \(str)"]
        
        task.launch()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            return output.components(separatedBy: "\n").filter({ $0 != "" })
        }
        return []
    }


    
    func decodeURL(_ url: String) -> Promise<YouGetJSON> {
        return Promise { resolver in
            switch Preferences.shared.liveDecoder {
            case .ykdl, .youget:
                guard let decoder = which(Preferences.shared.liveDecoder.rawValue).first else {
                    resolver.reject(DecodeUrlError.notFoundDecoder)
                    return
                }
                
                decodeTask = Process()
                let pipe = Pipe()
                let errorPipe = Pipe()
                decodeTask?.standardError = errorPipe
                decodeTask?.standardOutput = pipe
                
                decodeTask?.launchPath = decoder
                decodeTask?.arguments  = ["--json", url]
                Log(url)
                
                decodeTask?.terminationHandler = { _ in
                    guard self.decodeTask?.terminationReason != .uncaughtSignal else {
                        resolver.reject(DecodeUrlError.normalExit)
                        return
                    }
                    
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    
                    do {
                        let json = try JSONParser.JSONObjectWithData(data)
                        let re = try YouGetJSON(object: json)
                        resolver.fulfill(re)
                    } catch let er {
                        Log("JSON decode error: \(er)")
                        if let str = String(data: data, encoding: .utf8) {
                            Log("JSON string: \(str)")
                            if str.contains("Real URL") {
                                let url = str.subString(from: "['", to: "']")
                                let re = YouGetJSON(url: url)
                                resolver.fulfill(re)
                            }
                        }
                        resolver.reject(er)
                    }
                    
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if let str = String(data: errorData, encoding: .utf8), str != "" {
                        Log("Decode url error info: \(str)")
                    }
                }
                decodeTask?.launch()
            case .internal😀:
                videoGetTasks.append(decodeUrlWithVideoGet(url))
                videoGetTasks.last?.0.done {
                    resolver.fulfill($0)
                    }.catch(policy: .allErrors) {
                        switch $0 {
                        case PMKError.cancelled:
                            resolver.reject(PMKError.cancelled)
                        default:
                            resolver.reject($0)
                        }
                }
            }
        }
    }
    
    enum DecodeUrlError: Error {
        case normalExit
        
        case notFoundDecoder
    }
    
    func stopDecodeURL() {
        if let task = decodeTask, task.isRunning {
            decodeTask?.suspend()
            decodeTask?.terminate()
            decodeTask = nil
        }
        
        videoGetTasks.removeAll {
            $0.0.isFulfilled || $0.0.isRejected
        }
        videoGetTasks.last?.cancel()
    }
    
    func decodeUrlWithVideoGet(_ url: String) -> (Promise<YouGetJSON>, cancel: () -> Void) {
        var cancelme = false
        
        let promise = Promise<YouGetJSON> { resolver in
            self.videoGet.decodeUrl(url).done {
                guard !cancelme else { return resolver.reject(PMKError.cancelled) }
                resolver.fulfill($0)
                }.catch {
                    guard !cancelme else { return resolver.reject(PMKError.cancelled) }
                    resolver.reject($0)
            }
        }
        
        let cancel = {
            cancelme = true
        }
        return (promise, cancel)
    }
    
    enum PlayerOptions {
        case douyu, bilibili, withoutYtdl, none
    }
    
    func openWithPlayer(_ urls: [String], title: String, options: PlayerOptions) {
        let task = Process()
        let pipe = Pipe()
        task.standardInput = pipe
        var mpvArgs = ["\(MPVOption.Miscellaneous.forceMediaTitle)=\(title)"]
        getCookies(for: .douyu).done { cookies in
            switch options {
            case .douyu:
                mpvArgs.append(contentsOf: [MPVOption.Network.cookies,
                                            "\(MPVOption.Network.cookiesFile)=\(cookies)",
                    "\(MPVOption.ProgramBehavior.ytdl)=no"])
            case .bilibili:
                mpvArgs.append(contentsOf: ["\(MPVOption.ProgramBehavior.ytdl)=no",
                    "\(MPVOption.Network.referrer)=https://www.bilibili.com/"])
            case .withoutYtdl:
                mpvArgs.append("\(MPVOption.ProgramBehavior.ytdl)=no")
            case .none: break
            }
            }.ensure {
                let mergeWithEdl = true
                if !mergeWithEdl {
                    if urls.count > 1 {
                        mpvArgs.append(MPVOption.ProgramBehavior.mergeFiles)
                    }
                }
                
                switch Preferences.shared.livePlayer {
                case .iina:
                    task.launchPath = Preferences.shared.livePlayer.rawValue
                    mpvArgs = mpvArgs.map {
                        "--mpv-" + $0
                    }
                case .mpv:
                    task.launchPath = self.which(Preferences.shared.livePlayer.rawValue).first ?? ""
                    mpvArgs.append(MPVOption.Terminal.reallyQuiet)
                    mpvArgs = mpvArgs.map {
                        "--" + $0
                    }
                }
                if urls.count == 1 {
                    mpvArgs.append(urls.first ?? "")
                } else if urls.count > 1 {
                    if mergeWithEdl {
                        var edlString = urls.reduce(String()) { result, url in
                            var re = result
                            re += "%\(url.count)%\(url);"
                            return re
                        }
                        edlString = "edl://" + edlString
                        
                        mpvArgs.append(edlString)
                    } else {
                        mpvArgs.append(contentsOf: urls)
                    }
                    
                }
                if Preferences.shared.enableDanmaku {
                    mpvArgs.append("--danmaku")
                }
                
                Log("Player arguments: \(mpvArgs)")
                task.arguments = mpvArgs
                task.launch()
            }.catch {
                Log("Get video cookies error: \($0)")
        }
    }
    
}

private extension Processes {
    func getCookies(for website: LiveSupportList) -> Promise<String> {
        return Promise { resolver in
            switch website {
            case .douyu:
                let douyuCookie = "https://passport.douyu.com/lapi/did/api/get"
                let time = UInt32(NSDate().timeIntervalSinceReferenceDate)
                srand48(Int(time))
                let random = "\(drand48())"
                let parameters = ["client_id": "1",
                                  "callback": ("jsonp_" + random).replacingOccurrences(of: ".", with: "")]
                let headers = ["Referer": "http://www.douyu.com"]
                
                HTTP.GET(douyuCookie, parameters: parameters, headers: headers) { response in
                    if let error = response.error {
                        resolver.reject(error)
                    }
                    do {
                        var str = response.text
                        str = str?.subString(from: "(", to: ")")
                        let json = try JSONParser.JSONObjectWithData(str?.data(using: .utf8) ?? Data())
                        let didStr: String = try json.value(for: "data.did")
                        let date = Int(Date().timeIntervalSince1970)
                        let cookiesString = """
                        ..douyu.com    TRUE    /    FALSE    \(date)    dy_did    \(didStr)
                        .www.douyu.com    TRUE    /    FALSE    \(date)    acf_did    \(didStr)
                        """
                        
                        resolver.fulfill(cookiesString)
                    } catch let error {
                        resolver.reject(error)
                    }
                }
            default:
                resolver.fulfill("")
            }
        }
    }
}
