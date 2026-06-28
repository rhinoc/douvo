# 高级 Prompt

English: [Advanced Prompts](./advanced-prompts.md)

Douvo 的高级 prompt 编辑器位于 **Settings... -> AI -> Advanced**。

优先使用结构化设置：词库、标点、去水词、弱化情绪、输出风格，以及自定义输出风格指令。只有这些控制项不够表达需求时，再覆盖完整 prompt。

## Prompt 字段

| 字段 | 用途 | 留空行为 |
| --- | --- | --- |
| User Identity | 长期用户身份、领域、术语偏好或写作场景，用于理解意图和术语消歧。 | 不发送用户身份上下文。 |
| 增量提示词 | 追加到有效内置或自定义 System Prompt 之后的额外片段。 | 不追加任何内容。 |
| System Prompt | 定义 AI 后处理规则、词库处理、标点行为、输出风格和安全约束。 | 使用应用内置 system prompt。 |
| User Message | 包装原始转写文本，然后发送给选中的 AI 后端。 | 使用应用内置 user message 模板。 |

## 模板语法

Douvo 支持一小部分类似 Mustache 的语法：

| 语法 | 含义 |
| --- | --- |
| `{{variable}}` | 插入变量值。未知变量会渲染为空文本。 |
| `{{#if variable}}...{{/if}}` | 只有变量值非空时才渲染这个区块。 |
| `{{#if variable}}...{{else}}...{{/if}}` | 变量值非空时渲染前半段，否则渲染 `else` 后半段。 |

## 变量

| 变量 | 可用于 | 值 |
| --- | --- | --- |
| `original` | System Prompt, User Message | 原始转写文本或合并后的 ASR 输入文本。User Message 通常应该包含这个变量。 |
| `selected_text` | System Prompt, User Message | 选区编辑模式下作为编辑对象的选中文本。普通听写时为空。 |
| `vocabularies` | System Prompt, User Message | 根据用户词库和当前转写生成的候选映射，例如 `source => target`。没有候选时为空。 |
| `punctuation_style` | System Prompt, User Message | 机器可读的标点风格值，例如 `complete_punctuation`。 |
| `punctuation_instruction` | System Prompt, User Message | 当前标点风格对应的人类可读指令。 |
| `remove_filler_words` | System Prompt, User Message | 开启去水词时为 `true`，否则为空。 |
| `soften_emotional_language` | System Prompt, User Message | 开启弱化情绪时为 `true`，否则为空。 |
| `output_style_instruction` | System Prompt, User Message | 由输出风格、风格强度或自定义输出风格生成的指令。Output Style 为 `Original` 时为空。 |
| `environment_context` | System Prompt, User Message | 可选的当前环境信息，例如本地时间、星期、时区、前台应用，以及用户开启时的窗口标题。所有上下文开关关闭或没有可用值时为空。 |
| `user_identity` | System Prompt, User Message | 用户主动提供的身份、领域、术语偏好或写作场景。User Identity 为空时为空。 |

## 示例

最小 User Message：

```text
原始转写：
{{original}}

只输出最终正文：
```

有条件地插入词库候选：

```text
{{#if vocabularies}}
# 可能的识别错误候选
{{vocabularies}}
{{/if}}
```

选区编辑分支：

```text
{{#if selected_text}}
选中文本：
{{selected_text}}

语音编辑指令：
{{original}}

只输出改写后的选中文本：
{{else}}
原始转写：
{{original}}

只输出最终正文：
{{/if}}
```

有条件地插入输出风格：

```text
{{#if output_style_instruction}}
# 输出风格
{{output_style_instruction}}
{{/if}}
```

有条件地插入当前环境：

```text
{{#if environment_context}}
# 当前环境
只用于消歧、术语判断、日期时间理解和输出场景判断。不要根据它新增事实。

{{environment_context}}
{{/if}}
```

有条件地插入用户身份：

```text
{{#if user_identity}}
# 用户身份
只用于理解意图和术语消歧，不要输出它。

{{user_identity}}
{{/if}}
```

## 注意事项

- 输出要求保持简短、明确。
- 小范围补充规则优先使用增量提示词，再考虑覆盖完整 System Prompt。
- 不要要求模型解释修改原因；Douvo 会直接插入最终输出。
- 除非用户明确要求转换，否则应保留代码、路径、命令、URL、人名和词库术语。
- 翻译或格式化工作流优先使用 **Output Style -> Custom**，再考虑覆盖完整 System Prompt。
