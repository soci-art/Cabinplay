// SPDX-FileCopyrightText: 2026 CabinPlay.org
// SPDX-License-Identifier: AGPL-3.0-only
//
// 车标库:CarPlay 界面里「汽车」格子的图标(oemIcon)按车机自报的名字
// 自动认品牌——连接时蓝牙广播/ServerInfo 里带车名(如「长安UNI-V」),
// 按下面的关键词表从上到下做包含匹配(不分大小写),先命中先用;
// 一个都没命中就用 CabinPlay 自己的图标和名字兜底。
// 图标只作显示,不接任何点击操作。图片在 VehicleIcons/ 里(192×192,
// 接收端读 oemIcon 尺寸时只认 192 以内的方形 PNG,见 CarPlayInfo)。
// 本文件由 icon-library/mapping.json 生成,品牌顺序即匹配优先级:
// 子品牌(深蓝/哈弗/腾势…)排在母品牌(长安/长城/比亚迪)前面。

import Foundation

enum VehicleIcons {
    struct Entry {
        let slug: String
        let label: String
        let keywords: [String]
    }

    static let entries: [Entry] = [
        Entry(slug: "deepal", label: "深蓝", keywords: ["深蓝", "DEEPAL"]),
        Entry(slug: "avatr", label: "阿维塔", keywords: ["阿维塔", "AVATR"]),
        Entry(slug: "changan", label: "长安", keywords: ["长安", "CHANGAN", "UNI-V", "UNI-K", "UNI-T", "UNI-Z", "欧尚", "OSHANG", "启源", "QIYUAN"]),
        Entry(slug: "haval", label: "哈弗", keywords: ["哈弗", "HAVAL"]),
        Entry(slug: "tank", label: "坦克", keywords: ["坦克", "TANK"]),
        Entry(slug: "wey", label: "魏牌", keywords: ["魏牌", "WEY"]),
        Entry(slug: "ora", label: "欧拉", keywords: ["欧拉", "ORA"]),
        Entry(slug: "great-wall", label: "长城", keywords: ["长城", "GREAT WALL", "GWM"]),
        Entry(slug: "yangwang", label: "仰望", keywords: ["仰望", "YANGWANG"]),
        Entry(slug: "fangchengbao", label: "方程豹", keywords: ["方程豹", "FANGCHENGBAO"]),
        Entry(slug: "denza", label: "腾势", keywords: ["腾势", "DENZA"]),
        Entry(slug: "byd", label: "比亚迪", keywords: ["比亚迪", "BYD"]),
        Entry(slug: "zeekr", label: "极氪", keywords: ["极氪", "ZEEKR"]),
        Entry(slug: "geely", label: "吉利", keywords: ["吉利", "GEELY", "银河"]),
        Entry(slug: "jetour", label: "捷途", keywords: ["捷途", "JETOUR"]),
        Entry(slug: "exeed", label: "星途", keywords: ["星途", "EXEED"]),
        Entry(slug: "icar", label: "iCAR", keywords: ["ICAR", "iCAR"]),
        Entry(slug: "chery", label: "奇瑞", keywords: ["奇瑞", "CHERY"]),
        Entry(slug: "aion", label: "埃安", keywords: ["埃安", "AION", "昊铂"]),
        Entry(slug: "trumpchi", label: "传祺", keywords: ["传祺", "TRUMPCHI", "广汽", "GAC"]),
        Entry(slug: "roewe", label: "荣威", keywords: ["荣威", "ROEWE"]),
        Entry(slug: "mg", label: "名爵", keywords: ["名爵", "MG"]),
        Entry(slug: "maxus", label: "上汽大通", keywords: ["大通", "MAXUS"]),
        Entry(slug: "rising", label: "飞凡", keywords: ["飞凡", "RISING"]),
        Entry(slug: "saic-motor", label: "上汽", keywords: ["上汽", "SAIC"]),
        Entry(slug: "hongqi", label: "红旗", keywords: ["红旗", "HONGQI"]),
        Entry(slug: "bestune", label: "奔腾", keywords: ["奔腾", "BESTUNE"]),
        Entry(slug: "faw", label: "一汽", keywords: ["一汽", "FAW"]),
        Entry(slug: "arcfox", label: "极狐", keywords: ["极狐", "ARCFOX"]),
        Entry(slug: "baic-motor", label: "北汽", keywords: ["北汽", "BAIC", "北京汽车"]),
        Entry(slug: "voyah", label: "岚图", keywords: ["岚图", "VOYAH"]),
        Entry(slug: "dongfeng", label: "东风", keywords: ["东风", "DONGFENG"]),
        Entry(slug: "venucia", label: "启辰", keywords: ["启辰", "VENUCIA"]),
        Entry(slug: "wuling", label: "五菱", keywords: ["五菱", "WULING"]),
        Entry(slug: "baojun", label: "宝骏", keywords: ["宝骏", "BAOJUN"]),
        Entry(slug: "onvo", label: "乐道", keywords: ["乐道", "ONVO"]),
        Entry(slug: "nio", label: "蔚来", keywords: ["蔚来", "NIO"]),
        Entry(slug: "xpeng", label: "小鹏", keywords: ["小鹏", "XPENG"]),
        Entry(slug: "li-auto", label: "理想", keywords: ["理想", "LI AUTO", "LIAUTO"]),
        Entry(slug: "leapmotor", label: "零跑", keywords: ["零跑", "LEAPMOTOR"]),
        Entry(slug: "volkswagen", label: "大众", keywords: ["大众", "VOLKSWAGEN"]),
        Entry(slug: "audi", label: "奥迪", keywords: ["奥迪", "AUDI"]),
        Entry(slug: "bmw", label: "宝马", keywords: ["宝马", "BMW"]),
        Entry(slug: "mercedes-benz", label: "奔驰", keywords: ["奔驰", "MERCEDES", "BENZ"]),
        Entry(slug: "lexus", label: "雷克萨斯", keywords: ["雷克萨斯", "LEXUS"]),
        Entry(slug: "toyota", label: "丰田", keywords: ["丰田", "TOYOTA"]),
        Entry(slug: "honda", label: "本田", keywords: ["本田", "HONDA"]),
        Entry(slug: "nissan", label: "日产", keywords: ["日产", "NISSAN", "尼桑"]),
        Entry(slug: "mazda", label: "马自达", keywords: ["马自达", "MAZDA"]),
        Entry(slug: "buick", label: "别克", keywords: ["别克", "BUICK"]),
        Entry(slug: "chevrolet", label: "雪佛兰", keywords: ["雪佛兰", "CHEVROLET"]),
        Entry(slug: "cadillac", label: "凯迪拉克", keywords: ["凯迪拉克", "CADILLAC"]),
        Entry(slug: "ford", label: "福特", keywords: ["福特", "FORD"]),
        Entry(slug: "jeep", label: "Jeep", keywords: ["JEEP", "吉普"]),
        Entry(slug: "hyundai", label: "现代", keywords: ["现代", "HYUNDAI"]),
        Entry(slug: "kia", label: "起亚", keywords: ["起亚", "KIA"]),
        Entry(slug: "volvo", label: "沃尔沃", keywords: ["沃尔沃", "VOLVO"]),
        Entry(slug: "tesla", label: "特斯拉", keywords: ["特斯拉", "TESLA"]),
        Entry(slug: "porsche", label: "保时捷", keywords: ["保时捷", "PORSCHE"]),
        Entry(slug: "land-rover", label: "路虎", keywords: ["路虎", "LAND ROVER", "RANGE ROVER"]),
        Entry(slug: "subaru", label: "斯巴鲁", keywords: ["斯巴鲁", "SUBARU"]),
        Entry(slug: "mitsubishi", label: "三菱", keywords: ["三菱", "MITSUBISHI"]),
        Entry(slug: "skoda", label: "斯柯达", keywords: ["斯柯达", "SKODA"]),
        Entry(slug: "peugeot", label: "标致", keywords: ["标致", "PEUGEOT"]),
        Entry(slug: "citroen", label: "雪铁龙", keywords: ["雪铁龙", "CITROEN"]),
        Entry(slug: "suzuki", label: "铃木", keywords: ["铃木", "SUZUKI"]),
    ]

    /// 按车名选图标:返回 (PNG 数据, 显示标签, 命中说明)。
    static func icon(forCarName name: String?) -> (data: Data, label: String, matched: String) {
        if let name, !name.isEmpty {
            let haystack = name.uppercased()
            for entry in entries {
                if entry.keywords.contains(where: { haystack.contains($0.uppercased()) }),
                   let data = pngData(entry.slug) {
                    return (data, entry.label, entry.label)
                }
            }
        }
        // 兜底:CabinPlay 自己的图标和名字。
        if let data = pngData("cabinplay") {
            return (data, "CabinPlay", "兜底 CabinPlay")
        }
        // 图标文件万一不在包里,返回 1×1 透明 PNG 占位,别让会话起不来。
        let placeholder = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!
        return (placeholder, "CabinPlay", "兜底占位")
    }

    private static func pngData(_ slug: String) -> Data? {
        if let url = Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: "VehicleIcons") {
            return try? Data(contentsOf: url)
        }
        if let url = Bundle.main.url(forResource: slug, withExtension: "png") {
            return try? Data(contentsOf: url)
        }
        return nil
    }
}

