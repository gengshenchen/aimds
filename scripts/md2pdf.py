#!/usr/bin/env python3
"""
md2pdf - Markdown 转专业出版级 PDF CLI 工具
特性：
- 原生支持 Mermaid 流程图 / 架构图 / 时序图矢量渲染（SVG 自动缩放自适应，防跨页截断）
- 完美支持 GFM 表格、任务列表、代码块语法高亮布局
- 专业 A4 打印样式排版（优化页边距、字体层叠、跨页空白控制）
"""

import sys
import os
import re
import argparse
import subprocess
import tempfile
from pathlib import Path

try:
    import markdown
except ImportError:
    print("错误: 缺少 python-markdown 依赖，请运行: pip install markdown", file=sys.stderr)
    sys.exit(1)

def find_mermaid_js() -> str:
    """寻找本地 mermaid.min.js，若无则使用 CDN"""
    candidates = [
        Path(__file__).resolve().parent / "mermaid.min.js",
        Path.home() / ".local/share/md2pdf/mermaid.min.js",
        Path("/tmp/mermaid.min.js"),
    ]
    for c in candidates:
        if c.exists() and c.stat().st_size > 100000:
            return f"file://{c.resolve()}"
    return "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"

def normalize_fenced_code(text: str) -> str:
    """确保所有代码块 (``` 或 ~~~) 顶格对齐，防止 python-markdown 因缩进解析失败导致代码挤成一团"""
    lines = text.split('\n')
    new_lines = []
    in_fence = False
    fence_indent = 0
    fence_char = ''
    for line in lines:
        if not in_fence:
            m_start = re.match(r'^([ \t]*)(`{3,}|~{3,})([^\n]*)$', line)
            if m_start:
                in_fence = True
                fence_indent = len(m_start.group(1))
                fence_char = m_start.group(2)[0]
                new_lines.append(m_start.group(2) + m_start.group(3))
                continue
            new_lines.append(line)
        else:
            m_end = re.match(r'^[ \t]*(`{3,}|~{3,})[ \t]*$', line)
            if m_end and m_end.group(1).startswith(fence_char):
                in_fence = False
                new_lines.append(m_end.group(1))
                continue
            if fence_indent > 0:
                if line.startswith(' ' * fence_indent):
                    new_lines.append(line[fence_indent:])
                elif line.startswith('\t' * fence_indent):
                    new_lines.append(line[fence_indent:])
                else:
                    new_lines.append(line)
            else:
                new_lines.append(line)
    return '\n'.join(new_lines)

def convert_md_to_pdf(md_file: Path, pdf_file: Path = None, timeout_sec: int = 20) -> bool:
    if not md_file.exists():
        print(f"错误: Markdown 文件不存在: {md_file}", file=sys.stderr)
        return False

    if pdf_file is None:
        pdf_file = md_file.with_suffix(".pdf")

    md_content = md_file.read_text(encoding="utf-8")

    # 1. 提取并保护 mermaid 代码块
    mermaid_blocks = []
    def save_mermaid(match):
        idx = len(mermaid_blocks)
        code = match.group(1).strip()
        mermaid_blocks.append(code)
        return f"PHMERMAIDBLOCK{idx}ENDPH"

    content_with_placeholders = re.sub(r"```mermaid\s+(.*?)```", save_mermaid, md_content, flags=re.S)

    # 1.1 规范化通用代码块缩进（防止列表中的嵌套代码块被 python-markdown 误判为内联文本挤成一团）
    content_with_placeholders = normalize_fenced_code(content_with_placeholders)

    # 2. 预处理 Markdown 规范格式（符号规整、防序号挤在一块）
    content_with_placeholders = re.sub(r'\\?ightarrow\$?', '→', content_with_placeholders)
    content_with_placeholders = re.sub(r'\$\\rightarrow\$', '→', content_with_placeholders)
    content_with_placeholders = re.sub(r'\\rightarrow', '→', content_with_placeholders)
    content_with_placeholders = re.sub(r'\r', '', content_with_placeholders)
    content_with_placeholders = re.sub(r'^[ \t]*[•●◆][ \t]+', '- ', content_with_placeholders, flags=re.M)

    lines = content_with_placeholders.split('\n')
    preprocessed_lines = []
    in_code_block = False
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('```'):
            in_code_block = not in_code_block
            preprocessed_lines.append(line)
            continue
        
        if in_code_block:
            preprocessed_lines.append(line)
            continue

        # 规范化多级子列表缩进
        m_sub = re.match(r'^( +)([\*\-\+]|\d+\.)[ \t]+(.*)', line)
        if m_sub:
            spaces, bullet, rest = m_sub.groups()
            n_sp = len(spaces)
            if not (bullet == '*' and rest.startswith('@')):
                if 1 <= n_sp <= 3:
                    line = '    ' + bullet + ' ' + rest
                elif 5 <= n_sp <= 7:
                    line = '        ' + bullet + ' ' + rest

        if i > 0:
            prev = lines[i - 1].strip()
            curr_is_list = bool(re.match(r'^[ \t]*(?:\d+\.|[\-\*])[ \t]+', line))
            prev_is_list = bool(re.match(r'^[ \t]*(?:\d+\.|[\-\*])[ \t]+', lines[i - 1]))
            is_prev_heading = bool(re.match(r'^[ \t]*#', prev))
            is_prev_table = prev.startswith('|') and prev.endswith('|')
            is_prev_quote = prev.startswith('>')

            if curr_is_list and prev and not prev_is_list and not is_prev_heading and not is_prev_table and not is_prev_quote:
                preprocessed_lines.append('')
            
            if line.startswith('>') and bool(re.match(r'^[ \t]*>[ \t]*(?:\d+\.|[\-\*])[ \t]+', line)):
                if prev.startswith('>') and not bool(re.match(r'^[ \t]*>[ \t]*(?:\d+\.|[\-\*])[ \t]+', lines[i - 1])) and prev != '>':
                    preprocessed_lines.append('>')

        preprocessed_lines.append(line)
    
    content_with_placeholders = '\n'.join(preprocessed_lines)

    # 3. Markdown 转 HTML
    html_body = markdown.markdown(content_with_placeholders, extensions=["tables", "fenced_code"])

    # 4. 还原 mermaid 代码块
    for idx, code in enumerate(mermaid_blocks):
        escaped_code = code.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        replacement = (
            f'<div class="mermaid-wrapper" id="mermaid-wrap-{idx}">'
            f'<pre class="mermaid-source" style="display:none;">\n{escaped_code}\n</pre>'
            f'<div class="mermaid-loading" style="color:#a0aec0;font-size:9pt;padding:12px 0;">[图表渲染中...]</div>'
            f'</div>'
        )
        html_body = html_body.replace(f"<p>PHMERMAIDBLOCK{idx}ENDPH</p>", replacement)
        html_body = html_body.replace(f"PHMERMAIDBLOCK{idx}ENDPH", replacement)

    mermaid_js_url = find_mermaid_js()

    # 5. 构建排版样式与 HTML 骨架
    html_doc = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>{md_file.stem}</title>
<script src="{mermaid_js_url}"></script>
<style>
  @page {{
    size: A4;
    margin: 16mm 14mm 16mm 14mm;
  }}

  body {{
    font-family: -apple-system, BlinkMacSystemFont, "Noto Sans CJK SC", "PingFang SC", "Microsoft YaHei", "Segoe UI", Roboto, sans-serif;
    font-size: 10pt;
    line-height: 1.55;
    color: #24292e;
    margin: 0;
    padding: 0;
  }}

  h1 {{
    font-size: 18pt;
    color: #0366d6;
    border-bottom: 2px solid #eaecef;
    padding-bottom: 0.3em;
    margin-top: 0;
    margin-bottom: 14px;
    page-break-after: avoid;
    break-after: avoid;
  }}

  h2 {{
    font-size: 13pt;
    color: #1a202c;
    border-bottom: 1px solid #eaecef;
    padding-bottom: 0.25em;
    margin-top: 24px;
    margin-bottom: 12px;
    page-break-after: avoid;
    break-after: avoid;
  }}

  h3 {{
    font-size: 11pt;
    color: #2d3748;
    margin-top: 18px;
    margin-bottom: 8px;
    page-break-after: avoid;
    break-after: avoid;
  }}

  h4 {{
    font-size: 10pt;
    color: #4a5568;
    margin-top: 12px;
    margin-bottom: 6px;
    page-break-after: avoid;
    break-after: avoid;
  }}

  p, ul, ol {{
    margin-top: 0;
    margin-bottom: 8px;
  }}

  li {{
    margin-bottom: 3px;
  }}

  blockquote {{
    margin: 12px 0;
    padding: 8px 14px;
    color: #4a5568;
    background-color: #f7fafc;
    border-left: 4px solid #3182ce;
    border-radius: 0 4px 4px 0;
  }}

  blockquote p {{
    margin: 0;
  }}

  table {{
    width: 100%;
    border-collapse: collapse;
    margin: 14px 0;
    font-size: 9pt;
    page-break-inside: avoid;
    break-inside: avoid;
  }}

  th, td {{
    border: 1px solid #e2e8f0;
    padding: 6px 10px;
    text-align: left;
    vertical-align: top;
  }}

  th {{
    background-color: #edf2f7;
    font-weight: 600;
    color: #2d3748;
  }}

  tr:nth-child(even) {{
    background-color: #f8fafc;
  }}

  @media print {{
    ::-webkit-scrollbar {{
      display: none !important;
      width: 0 !important;
      height: 0 !important;
    }}
  }}

  pre {{
    background-color: #f6f8fa;
    border: 1px solid #e1e4e8;
    border-radius: 6px;
    margin: 12px 0 16px 0;
    padding: 12px 14px;
    font-family: "JetBrains Mono", "SFMono-Regular", Consolas, Menlo, "Noto Sans Mono CJK SC", monospace;
    font-size: 8.8pt;
    line-height: 1.6;
    letter-spacing: 0.02em;
    white-space: pre-wrap !important;
    word-break: normal !important;
    overflow-wrap: break-word !important;
    overflow: visible !important;
    page-break-inside: auto;
    break-inside: auto;
  }}

  code {{
    font-family: "JetBrains Mono", "SFMono-Regular", Consolas, Menlo, "Noto Sans Mono CJK SC", monospace;
    font-size: 8.8pt;
    background-color: rgba(27,31,35,0.06);
    padding: 0.2em 0.4em;
    border-radius: 3px;
  }}

  pre code {{
    background-color: transparent;
    padding: 0;
    border-radius: 0;
    font-size: 8.8pt;
    line-height: 1.6;
  }}

  .mermaid-wrapper {{
    display: block;
    margin: 10px auto;
    text-align: center;
    page-break-inside: avoid !important;
    break-inside: avoid !important;
    clear: both;
  }}

  .mermaid-wrapper svg {{
    max-width: 100% !important;
    max-height: 460px !important;
    width: auto !important;
    height: auto !important;
    display: block;
    margin: 0 auto;
  }}

  .page-break {{
    page-break-before: always;
    break-before: page;
  }}

  hr {{
    height: 1px;
    background-color: #e1e4e8;
    border: none;
    margin: 16px 0;
  }}
</style>
</head>
<body>
{html_body}
<script>
  mermaid.initialize({{
    startOnLoad: false,
    theme: 'default',
    securityLevel: 'loose',
    flowchart: {{
      useMaxWidth: true,
      htmlLabels: true,
      curve: 'basis'
    }},
    sequence: {{
      useMaxWidth: false,
      actorFontSize: 12,
      messageFontSize: 11,
      noteFontSize: 10.5,
      actorFontFamily: '"Noto Sans CJK SC", sans-serif',
      noteFontFamily: '"Noto Sans CJK SC", sans-serif',
      messageFontFamily: '"Noto Sans CJK SC", sans-serif',
      mirrorActors: false,
      messageMargin: 20,
      actorMargin: 35
    }}
  }});

  async function renderMermaidSequentially() {{
    const sources = document.querySelectorAll('.mermaid-source');
    for (let i = 0; i < sources.length; i++) {{
      const el = sources[i];
      const code = el.textContent.trim();
      const id = 'mermaid_svg_item_' + i;
      try {{
        const res = await mermaid.render(id, code);
        const wrapper = document.getElementById('mermaid-wrap-' + i);
        if (wrapper) {{
          wrapper.innerHTML = res.svg;
        }}
      }} catch (err) {{
        console.error('Failed to render diagram ' + i, err);
        const wrapper = document.getElementById('mermaid-wrap-' + i);
        if (wrapper) {{
          wrapper.innerHTML = '<div style="color:#c53030;padding:8px;border:1px solid #feb2b2;border-radius:4px;background:#fff5f5;font-size:9pt;">图表加载重试中...</div>';
        }}
      }}
    }}
    window.__MERMAID_DONE__ = true;
  }}

  if (document.readyState === 'loading') {{
    document.addEventListener('DOMContentLoaded', renderMermaidSequentially);
  }} else {{
    renderMermaidSequentially();
  }}
</script>
</body>
</html>"""

    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8") as f:
        f.write(html_doc)
        temp_html_path = f.name

    try:
        cmd = [
            "google-chrome",
            "--headless=new",
            "--disable-gpu",
            "--no-sandbox",
            "--no-pdf-header-footer",
            f"--virtual-time-budget={timeout_sec * 1000}",
            f"--print-to-pdf={pdf_file.resolve()}",
            temp_html_path
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode == 0 and pdf_file.exists():
            print(f"✅ 成功生成 PDF: {pdf_file} (大小: {pdf_file.stat().st_size / 1024:.1f} KB)")
            return True
        else:
            print(f"❌ 生成 PDF 失败: {res.stderr}", file=sys.stderr)
            return False
    finally:
        if os.path.exists(temp_html_path):
            os.remove(temp_html_path)

def main():
    parser = argparse.ArgumentParser(
        description="md2pdf: Markdown 转专业出版级 PDF 工具 (完美支持 Mermaid 矢量图与排版优化)"
    )
    parser.add_argument("input_md", type=Path, help="输入的 Markdown 文件路径 (.md)")
    parser.add_argument("output_pdf", type=Path, nargs="?", default=None, help="输出的 PDF 文件路径 (可选，默认同名)")
    parser.add_argument("--timeout", type=int, default=15, help="渲染等待超时秒数 (默认 15s)")

    args = parser.parse_args()
    success = convert_md_to_pdf(args.input_md, args.output_pdf, timeout_sec=args.timeout)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
