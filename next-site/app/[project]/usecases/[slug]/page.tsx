import { getProject, PROJECT_IDS } from '@/lib/projects'
import { loadUseCaseSource } from '@/lib/content-loader'
import { notFound } from 'next/navigation'
import { MDXRemote } from 'next-mdx-remote/rsc'
import { MDX_COMPONENTS } from '@/components/MDXComponents'
import matter from 'gray-matter'
import Link from 'next/link'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import remarkGfm from 'remark-gfm'
import rehypeSlug from 'rehype-slug'
import rehypePrettyCode from 'rehype-pretty-code'
import { extractHeadings } from '@/lib/extract-headings'
import { TableOfContents } from '@/components/TableOfContents'

export function generateStaticParams() {
  const params: { project: string; slug: string }[] = []
  for (const projectId of PROJECT_IDS) {
    const proj = getProject(projectId)!
    for (const slug of proj.usecases) {
      params.push({ project: projectId, slug })
    }
  }
  return params
}

export default async function UseCasePage({ params }: { params: { project: string; slug: string } }) {
  const project = getProject(params.project)
  if (!project) notFound()

  const source = loadUseCaseSource(project.id, params.slug)
  if (!source) notFound()

  const { content, data } = matter(source)
  const headings = extractHeadings(content)

  const slugIndex = project.usecases.indexOf(params.slug)
  const prevSlug = slugIndex > 0 ? project.usecases[slugIndex - 1] : null
  const nextSlug = slugIndex < project.usecases.length - 1 ? project.usecases[slugIndex + 1] : null

  return (
    <div className="flex min-w-0">
      <article className="flex-1 min-w-0 px-8 py-10">
        <div>
          {data.title && (
            <div className="mb-8">
              <span className="text-xs font-semibold uppercase tracking-wider text-[#2da44e] mb-2 block">
                🎯 使用情境
              </span>
              <h1 className="text-3xl font-bold text-white mb-3">{data.title}</h1>
              {data.description && (
                <p className="text-lg text-[#8b949e]">{data.description}</p>
              )}
            </div>
          )}
          <div className="prose-content">
            <MDXRemote
              source={content}
              components={MDX_COMPONENTS as any}
              options={{
                mdxOptions: {
                  remarkPlugins: [remarkGfm],
                  rehypePlugins: [
                    [rehypePrettyCode, { theme: 'github-dark', keepBackground: true }] as any,
                    rehypeSlug,
                  ],
                },
              }}
            />
          </div>

          <div className="mt-12 pt-6 border-t border-[#30363d] flex items-center justify-between">
            {prevSlug ? (
              <Link href={`/${project.id}/usecases/${prevSlug}`}
                className="flex items-center gap-2 text-sm text-[#8b949e] hover:text-white transition-colors">
                <ChevronLeft size={16} /> 上一個情境
              </Link>
            ) : <div />}
            {nextSlug ? (
              <Link href={`/${project.id}/usecases/${nextSlug}`}
                className="flex items-center gap-2 text-sm text-[#8b949e] hover:text-white transition-colors">
                下一個情境 <ChevronRight size={16} />
              </Link>
            ) : <div />}
          </div>
        </div>
      </article>

      <TableOfContents headings={headings} />
    </div>
  )
}
