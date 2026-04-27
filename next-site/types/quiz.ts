export interface QuizOption {
  text: string
}

export interface QuizItem {
  id: number
  question: string
  options: string[]
  answer: number
  explanation: string
}
