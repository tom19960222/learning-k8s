import { getProject, PROJECT_IDS } from '@/lib/projects'
import { loadFeatureSource } from '@/lib/content-loader'
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
    for (const slug of proj.features) {
      params.push({ project: projectId, slug })
    }
  }
  return params
}

export default async function FeaturePage({ params }: { params: { project: string; slug: string } }) {
  const project = getProject(params.project)
  if (!project) notFound()

  const source = loadFeatureSource(project.id, params.slug)
  if (!source) notFound()

  const { content, data } = matter(source)
  const headings = extractHeadings(content)

  const slugIndex = project.features.indexOf(params.slug)
  const prevSlug = slugIndex > 0 ? project.features[slugIndex - 1] : null
  const nextSlug = slugIndex < project.features.length - 1 ? project.features[slugIndex + 1] : null

  return (
    <div className="flex min-w-0">
      {/* Main content — flex-1 fills all available space; max-w applied to inner content so ToC is flush right */}
      <article className="flex-1 min-w-0 px-8 py-10">
        <div>
          {data.title && (
            <div className="mb-8">
              {data.category && (
                <span className="text-xs font-semibold uppercase tracking-wider text-[#2f81f7] mb-2 block">
                  {data.category}
                </span>
              )}
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
              <Link href={`/${project.id}/features/${prevSlug}`}
                className="flex items-center gap-2 text-sm text-[#8b949e] hover:text-white transition-colors">
                <ChevronLeft size={16} /> 上一篇
              </Link>
            ) : <div />}
            {nextSlug ? (
              <Link href={`/${project.id}/features/${nextSlug}`}
                className="flex items-center gap-2 text-sm text-[#8b949e] hover:text-white transition-colors">
                下一篇 <ChevronRight size={16} />
              </Link>
            ) : <div />}
          </div>
        </div>
      </article>

      {/* Sticky Table of Contents */}
      <TableOfContents headings={headings} />
    </div>
  )
}
