import {Spider, aesX, htmlQuery, md5X} from 'catvod';

export default class SmokeSpider extends Spider {
    homeContent(filter) {
        const cipher = aesX('AES/CBC/PKCS7', true, '拾萤', false, '0123456789abcdef', 'fedcba9876543210', true);
        const plain = aesX('AES/CBC/PKCS7', false, cipher, true, '0123456789abcdef', 'fedcba9876543210', false);
        const title = htmlQuery.pdfh('<span class="n">运行时</span>', 'span.n&&Text');
        return {
            class: [
                {type_id: 'movie', type_name: title || '电影'},
            ],
            list: [
                {
                    vod_id: 'smoke-1',
                    vod_name: plain || '拾萤运行时测试',
                    vod_remarks: filter ? '已过滤' : md5X('firepick').slice(0, 8),
                },
            ],
        };
    }

    searchContent(key, quick, pg) {
        return {
            list: [
                {
                    vod_id: `search-${pg}`,
                    vod_name: `${key} · ${quick ? '快速' : '完整'}`,
                },
            ],
        };
    }
}
