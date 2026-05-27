// 待办事项应用 - 示例代码
// 参考实现

const STORAGE_KEY = 'todo_items';

class TodoApp {
    constructor() {
        this.items = this.loadItems();
        this.render();
    }

    loadItems() {
        const data = localStorage.getItem(STORAGE_KEY);
        return data ? JSON.parse(data) : [];
    }

    saveItems() {
        localStorage.setItem(STORAGE_KEY, JSON.stringify(this.items));
    }

    addItem(text) {
        if (!text.trim()) {
            alert('请输入内容');
            return;
        }
        this.items.unshift({
            id: Date.now(),
            text: text.trim(),
            completed: false
        });
        this.saveItems();
        this.render();
    }

    toggleItem(id) {
        const item = this.items.find(i => i.id === id);
        if (item) {
            item.completed = !item.completed;
            this.saveItems();
            this.render();
        }
    }

    deleteItem(id) {
        this.items = this.items.filter(i => i.id !== id);
        this.saveItems();
        this.render();
    }

    render() {
        const app = document.getElementById('app');
        const activeItems = this.items.filter(i => !i.completed);
        const completedItems = this.items.filter(i => i.completed);

        app.innerHTML = `
            <h1>Todo App</h1>
            <div class="input-group">
                <input type="text" id="todoInput" placeholder="输入任务...">
                <button id="addBtn">添加</button>
            </div>
            <ul>
                ${activeItems.map(item => this.renderItem(item)).join('')}
                ${completedItems.map(item => this.renderItem(item)).join('')}
            </ul>
            <div class="stats">
                待办: ${activeItems.length} | 已完成: ${completedItems.length}
            </div>
        `;

        document.getElementById('addBtn').addEventListener('click', () => {
            const input = document.getElementById('todoInput');
            this.addItem(input.value);
        });
    }

    renderItem(item) {
        return `
            <li class="${item.completed ? 'completed' : ''}">
                <input type="checkbox" ${item.completed ? 'checked' : ''}
                    onchange="app.toggleItem(${item.id})">
                <span>${item.text}</span>
                <button onclick="app.deleteItem(${item.id})">删除</button>
            </li>
        `;
    }
}

const app = new TodoApp();
