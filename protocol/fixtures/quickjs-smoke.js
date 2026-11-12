import {Spider} from 'catvod';

export default class SmokeSpider extends Spider {
    homeContent(filter) {
        return {
            class: [
                {type_id: 'movie', type_name: '电影'},
            ],
            list: [
                {
                    vod_id: 'smoke-1',
                    vod_name: '拾萤运行时测试',
                    vod_remarks: filter ? '已过滤' : '可用',
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
