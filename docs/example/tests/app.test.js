// 待办事项应用 - 测试用例
// 参考测试

describe('TodoApp', () => {
    beforeEach(() => {
        localStorage.clear();
        app = new TodoApp();
    });

    describe('添加任务', () => {
        test('应该添加新任务到列表', () => {
            app.addItem('测试任务');
            expect(app.items.length).toBe(1);
            expect(app.items[0].text).toBe('测试任务');
        });

        test('空内容不应该添加', () => {
            app.addItem('');
            expect(app.items.length).toBe(0);
        });
    });

    describe('完成任务', () => {
        test('应该标记任务为完成', () => {
            app.addItem('测试任务');
            app.toggleItem(app.items[0].id);
            expect(app.items[0].completed).toBe(true);
        });
    });

    describe('删除任务', () => {
        test('应该删除任务', () => {
            app.addItem('测试任务');
            const id = app.items[0].id;
            app.deleteItem(id);
            expect(app.items.length).toBe(0);
        });
    });

    describe('数据持久化', () => {
        test('应该保存到 localStorage', () => {
            app.addItem('测试任务');
            const data = localStorage.getItem(STORAGE_KEY);
            expect(data).not.toBeNull();
        });

        test('应该从 localStorage 恢复', () => {
            app.addItem('测试任务');
            const newApp = new TodoApp();
            expect(newApp.items.length).toBe(1);
        });
    });
});
