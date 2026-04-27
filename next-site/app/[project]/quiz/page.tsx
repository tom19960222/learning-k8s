import { getProject, PROJECT_IDS } from '@/lib/projects'
import { notFound } from 'next/navigation'
import { QuizQuestion } from '@/components/QuizQuestion'
import { existsSync, readFileSync } from 'fs'
import path from 'path'

export function generateStaticParams() {
  return PROJECT_IDS.map(id => ({ project: id }))
}

export default async function QuizPage({ params }: { params: { project: string } }) {
  const project = getProject(params.project)
  if (!project) notFound()

  const quizPath = path.join(process.cwd(), 'content', project.id, 'quiz.json')
  let quiz: any[] = []
  if (existsSync(quizPath)) {
    quiz = JSON.parse(readFileSync(quizPath, 'utf-8'))
  }

  return (
    <div className="max-w-3xl mx-auto px-8 py-10">
      <h1 className="text-3xl font-bold text-white mb-2">{project.displayName} 測驗</h1>
      <p className="text-[#8b949e] mb-8">測試你對 {project.shortName} 的理解程度</p>
      {quiz.length === 0 ? (
        <div className="text-[#8b949e]">測驗題目尚未建立</div>
      ) : (
        <div className="space-y-4">
          {quiz.map((q: any, i: number) => (
            <QuizQuestion
              key={q.id || i}
              question={`${i + 1}. ${q.question}`}
              options={q.options}
              answer={q.answer}
              explanation={q.explanation}
            />
          ))}
        </div>
      )}
    </div>
  )
}
