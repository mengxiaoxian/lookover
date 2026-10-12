// dsh-look: explicit, read-only window context for the official desktop.
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { appendFile, mkdir } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'dsh-look'
export const inject = ['tools', 'systemPrompt']

const ROOT = dirname(fileURLToPath(import.meta.url))
const HELPER = join(ROOT, '..', 'bin', 'look')
// Self-identification: the host (this process) is inside the DSH app.
const OFFICIAL_DESKTOP = process.execPath.includes('/DeepSeek Harness.app/Contents/')
const SELF_BUNDLE = process.env.DSH_SELF_BUNDLE || (OFFICIAL_DESKTOP ? 'com.deepseek.dsh' : 'local.menke.xiaoguang.dsh')
const EXCLUDED_BUNDLES = ['local.menke.xiaoguang.companion.proof']
const HELPER_TIMEOUT_MS = 8000
const PROMPT_TEXT = [
  '你可以用 look 工具查看用户当前正在使用的应用窗口。',
  '',
  '什么时候该用：',
  '- 用户的话里出现指代词：「这个」「他」「这份」「刚才那个」',
  '- 用户提到「当前窗口」「这个页面」「这个报错」「这个文档」',
  '- 用户的问题明显依赖屏幕上的内容，但没说清楚是什么',
  '',
  '什么时候不要用：',
  '- 问题与屏幕无关（写代码、算数、闲聊、通用知识）',
  '- 用户已经把内容贴出来了',
  '',
  'look 返回的是用户提问前正在使用的前台应用。',
  '- fidelity=app（零权限）：只有应用名、bundleId、窗口位置大小。如实说「我知道你在用 X，但看不到窗口内容」，不要猜测内容。',
  '- fidelity=ax（已授辅助功能）：额外返回窗口标题（ax.title）、文档路径（ax.document）、选中文本（ax.selected）、焦点元素文本（ax.focusedValue）。',
  '  这些是真实读取到的内容，可据此回答；但字段之外的画面内容仍不可见，不要猜测。',
  'look 返回 error 时，如实告诉用户看不到，不要编造。',
  '',
  'OCR 模式（look({ocr:true})）：',
  '- 适用：AX 读不到内容的场景——微信/QQ 聊天气泡、图片里的文字、扫描版 PDF、视频画面、设计稿。',
  '- 返回的 ocr.ocrText 是本地 OCR 结果，可能有识别错误；引用时注明「据 OCR 识别」，关键信息需与用户确认。',
  '- ocr.sidebar 是窗口左侧栏（聊天应用的会话列表常驻显示），ocr.content 是主内容区。',
  '  判断用户「正在看什么/停在哪个页面」以 ocr.content 为准，不要拿 sidebar 当全貌。',
  '- 多模态门控（gated）：默认只用 OCR 文本。只有问题确实是视觉语义类（图表趋势、颜色、布局、图形内容）时，',
  '  才用返回的 ocr.imagePath 配合 read_image 工具做一次视觉判断——不要每次都读图。',
  '- ocr 返回 capture_failed 时说明缺少屏幕录制权限，如实告知用户，不要假装看到内容。',
  '',
  '多窗口（pick 参数）：',
  '- 微信等应用点开聊天是独立窗口；结果里出现 windows 列表且 selected 不是用户所指时，',
  '  用 pick 按应用名或窗口名子串重试，例如 look({ocr:true, pick:"微信"})。',
  '- pick_no_match 时看 windows 列表换个子串再试；都失败再请用户把目标窗口点回最前。',
  '',
  '边界约束（重要）：',
  '- look 只用于了解上下文。当返回信息不足以完成用户指令时（例如「重新打开刚才那个网页」但无标题可读），',
  '  必须先向用户确认具体是哪个页面/哪段内容，再行动。',
  '- 不要通过翻浏览器历史、读标签页、猜 URL 等方式推断用户「刚才在看什么」——那等于变相编造屏幕内容。',
  '- look 及其后续动作不得改变前台应用（不激活窗口、不点击、不用 open 打开页面）。',
].join('\n')

function runHelper(extraArgs = []) {
  return new Promise((resolve, reject) => {
    if (process.platform !== 'darwin') {
      reject(new Error(`dsh-look only supports macOS (got ${process.platform})`))
      return
    }
    if (!existsSync(HELPER)) {
      reject(new Error(`look helper missing at ${HELPER}. Run npm run build:native.`))
      return
    }
    const child = spawn(HELPER, [...extraArgs, '--self-bundle', SELF_BUNDLE, ...EXCLUDED_BUNDLES.flatMap(bundle => ['--exclude-bundle', bundle]), '--self-pid', String(process.pid)], {
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => {
      child.kill('SIGKILL')
      reject(new Error('look helper timed out'))
    }, HELPER_TIMEOUT_MS)
    child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8') })
    child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8') })
    child.on('error', (error) => {
      clearTimeout(timer)
      reject(error)
    })
    child.on('exit', (code) => {
      clearTimeout(timer)
      const line = stdout.trim().split('\n').filter(Boolean).at(-1) || ''
      if (!line) {
        reject(new Error(stderr.trim() || `look helper exited ${code ?? 'unknown'}`))
        return
      }
      try { resolve(JSON.parse(line)) } catch {
        reject(new Error(stderr.trim() || 'look helper returned invalid JSON'))
      }
    })
  })
}

function logDir() {
  return process.env.DSH_HOME?.trim()
    ? join(process.env.DSH_HOME.trim(), 'look')
    : join(homedir(), '.dsh', 'look')
}

export function apply(ctx) {
  // 留痕（P0-8）：every agent-initiated read is appended here. Absence of
  // entries during a batch of questions is the A3 acceptance evidence.
  const audit = async (result) => {
    try {
      const dir = logDir()
      await mkdir(dir, { recursive: true })
      await appendFile(join(dir, 'log.jsonl'), `${JSON.stringify(result)}\n`)
    } catch (error) {
      ctx.logger?.warn?.(`[dsh-look] audit log write failed: ${error instanceof Error ? error.message : String(error)}`)
    }
  }

  ctx.systemPrompt.section({
    name: 'tool:look',
    order: (ctx.systemPrompt.getSectionOrder('TOOL_SESSION_QUERY') ?? 2300) + 10,
    text: PROMPT_TEXT,
  })

  ctx.tools.register({
    name: 'look',
    description:
      '查看用户当前正在使用的前台应用窗口（自动跳过 DSH 自身）。返回应用名、bundleId、pid、窗口 bounds；若已授予辅助功能权限（fidelity=ax），还返回窗口标题、文档路径、选中文本、焦点元素文本。当用户提到「这个」「他」「这个页面」「这个报错」等依赖屏幕上下文的指代时调用；与屏幕无关的问题不要调用。传 ocr:true 时额外对窗口截图并本地 OCR（适用于微信聊天气泡、图片、扫描 PDF 等 AX 盲区），返回 ocr.ocrText 与 ocr.imagePath。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        ocr: {
          type: 'boolean',
          description: '对窗口截图并做本地 Vision OCR（需要屏幕录制权限）。仅在 AX 读不到内容（聊天气泡/图片/扫描件/视频画面）或需要视觉语义时使用。',
        },
        pick: {
          type: 'string',
          description: '按应用名或窗口名子串选择目标窗口（不区分大小写），如 "微信"。缺省取最前窗口。结果里 windows 列表显示多个窗口且选中的不是用户所指时，用它重试。',
        },
      },
    },
    output: {
      schema: { type: 'object', additionalProperties: true },
      render: (_args, value) => [{ type: 'text', text: JSON.stringify(value, null, 2) }],
    },
    timeoutMs: HELPER_TIMEOUT_MS + 8000,
    isConcurrencySafe: () => true,
    async execute(args) {
      const extra = []
      if (args?.ocr) extra.push('--ocr')
      if (typeof args?.pick === 'string' && args.pick.trim()) extra.push('--pick', args.pick.trim())
      let result
      try {
        result = await runHelper(extra)
      } catch (error) {
        result = {
          error: 'helper_failed',
          note: error instanceof Error ? error.message : String(error),
          ts: Date.now(),
          source: 'agent',
        }
      }
      void audit(result)
      return result
    },
  })

}
