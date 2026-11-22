import Foundation

/// Spots romanized Chinese names that a Crossref deposit stored surname-first, such as
/// `{"given": "Wu", "family": "Haoyun"}` for Wu Haoyun.
///
/// Most deposits get the order right, and correctly ordered short given names look the
/// same at a glance: "R. Abbott", "Ian Goodfellow", and Chinese names like "Ze Liu" or
/// "Kai Chen". A swap is reported only when `given` is a common one-syllable Chinese
/// surname and `family` reads as a two-syllable pinyin given name that is not itself a
/// syllable (so not a surname like "Liu" or "Huang"). One-syllable given names
/// ("Liu, Min") stay ambiguous and are left as deposited.
enum RomanizedChineseName {
    static func looksSurnameFirst(given: String, family: String) -> Bool {
        let g = given.trimmingCharacters(in: .whitespaces)
        let f = family.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty, !f.isEmpty,
              g.allSatisfy(\.isASCII), f.allSatisfy(\.isASCII),
              !g.contains(" "), g.count <= 3, f.count > g.count,
              commonShortSurnames.contains(g.lowercased()) else {
            return false
        }
        // Given names may be written "Hao-Yun", "Hao Yun" or "Hao'yun".
        let name = f.lowercased().filter { $0 != "-" && $0 != " " && $0 != "'" }
        guard name.count > 1, name.allSatisfy(\.isLetter), !pinyinSyllables.contains(name) else {
            return false
        }
        return (1..<name.count).contains { split in
            pinyinSyllables.contains(String(name.prefix(split)))
                && pinyinSyllables.contains(String(name.dropFirst(split)))
        }
    }

    /// Common Chinese surnames whose pinyin has at most three letters (the only ones the
    /// swap check considers), leaving out a few that double as English given names.
    private static let commonShortSurnames: Set<String> = Set("""
        li liu wu xu sun ma zhu hu guo he lin gao luo xie han cao pan cai yu du ye wei su lu
        lv lyu ren yao tan fan jin shi jia xia fu zou bai qin qiu hou yin xue yan lei tao mao
        hao gu wan dai yi lai wen gan mei niu ni ge hua kou lan mu ou qi rao tu xi zuo bao bi
        ji nie pei qu shu xin you yue cui ran
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Mandarin syllables in toneless pinyin, grouped by initial.
    private static let pinyinSyllables: Set<String> = Set("""
        a ai an ang ao e ei en eng er o ou
        ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
        pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
        ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
        fa fan fang fei fen feng fo fou fu
        da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
        ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
        na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nun nuo
        la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo
        ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
        ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo
        ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
        ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
        qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
        xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
        zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo
        cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo
        sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo
        ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
        za zai zan zang zao ze zei zen zeng zi zong zou zu zuan zui zun zuo
        ca cai can cang cao ce cen ceng ci cong cou cu cuan cui cun cuo
        sa sai san sang sao se sen seng si song sou su suan sui sun suo
        ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
        wa wai wan wang wei wen weng wo wu
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}
