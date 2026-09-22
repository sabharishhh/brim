
import { motion } from 'framer-motion'
import ThreeScene from './components/ThreeScene'

export default function App() {
  return (
    <div className="min-h-screen bg-[#F5F5F7] text-[#1d1d1f] font-sans selection:bg-[#000000] selection:text-white relative overflow-hidden">
      
      {/* Background 3D Element */}
      <div className="fixed inset-0 w-full h-[100vh] z-0 pointer-events-none opacity-60">
        <ThreeScene />
      </div>

      {/* Navbar */}
      <nav className="fixed top-0 left-0 right-0 z-50 px-8 py-6 flex items-center justify-between mix-blend-multiply">
        <div className="text-xl font-semibold tracking-tight">Brim</div>
        <div className="flex items-center gap-6 text-sm font-medium">
          <a href="https://github.com/sabharishhh/brim.git" target="_blank" rel="noreferrer" className="text-[#1d1d1f]/60 hover:text-[#1d1d1f] transition-colors">GitHub</a>
          <button className="bg-[#1d1d1f] text-white px-4 py-2 rounded-full hover:bg-black transition-colors">
            Download
          </button>
        </div>
      </nav>

      <main className="relative z-10">
        {/* Hero Section */}
        <section className="min-h-screen flex flex-col items-center justify-center px-6 pt-20">
          <motion.div
            initial={{ opacity: 0, y: 30 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 1, ease: [0.16, 1, 0.3, 1] }}
            className="max-w-4xl mx-auto text-center"
          >
            <h1 className="text-6xl md:text-8xl font-semibold tracking-tighter leading-tight mb-8">
              Leave absolutely<br />nothing behind.
            </h1>
            <p className="text-xl md:text-2xl text-[#1d1d1f]/60 font-medium max-w-2xl mx-auto leading-relaxed mb-12">
              The cleanest way to remove macOS applications. Brim unloads background services, clears privacy grants, and purges hidden files safely.
            </p>
            <button className="bg-[#1d1d1f] text-white px-8 py-4 rounded-full text-lg font-medium hover:scale-105 transition-transform duration-300">
              Download for macOS
            </button>
          </motion.div>
        </section>

        {/* Value Prop 1 */}
        <section className="min-h-screen flex items-center px-6 md:px-24">
          <motion.div 
            initial={{ opacity: 0, y: 50 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-100px" }}
            transition={{ duration: 1, ease: [0.16, 1, 0.3, 1] }}
            className="max-w-2xl"
          >
            <h2 className="text-5xl md:text-7xl font-semibold tracking-tighter mb-6">Complete removal.</h2>
            <p className="text-xl md:text-2xl text-[#1d1d1f]/60 font-medium leading-relaxed">
              Dragging an app to the trash leaves gigabytes of cache, logs, and preference files scattered across your system. Brim finds and removes all of it.
            </p>
          </motion.div>
        </section>

        {/* Value Prop 2 */}
        <section className="min-h-screen flex items-center justify-end px-6 md:px-24">
          <motion.div 
            initial={{ opacity: 0, y: 50 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-100px" }}
            transition={{ duration: 1, ease: [0.16, 1, 0.3, 1] }}
            className="max-w-2xl text-right"
          >
            <h2 className="text-5xl md:text-7xl font-semibold tracking-tighter mb-6">Silent services, silenced.</h2>
            <p className="text-xl md:text-2xl text-[#1d1d1f]/60 font-medium leading-relaxed">
              Applications often leave background agents running indefinitely. Brim safely unloads daemons and halts forgotten processes before deleting them.
            </p>
          </motion.div>
        </section>

        {/* Value Prop 3 */}
        <section className="min-h-screen flex items-center px-6 md:px-24">
          <motion.div 
            initial={{ opacity: 0, y: 50 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-100px" }}
            transition={{ duration: 1, ease: [0.16, 1, 0.3, 1] }}
            className="max-w-2xl"
          >
            <h2 className="text-5xl md:text-7xl font-semibold tracking-tighter mb-6">Built for macOS.</h2>
            <p className="text-xl md:text-2xl text-[#1d1d1f]/60 font-medium leading-relaxed">
              Native performance. No electron bloat. Brim understands the macOS file system intimately and operates with cryptographic proof and safety.
            </p>
          </motion.div>
        </section>
        
        {/* Footer */}
        <footer className="py-12 px-6 md:px-24 flex flex-col md:flex-row items-center justify-between text-sm font-medium text-[#1d1d1f]/40 border-t border-[#1d1d1f]/5">
          <p>© {new Date().getFullYear()} Brim. All rights reserved.</p>
          <a href="https://github.com/sabharishhh/brim.git" target="_blank" rel="noreferrer" className="hover:text-[#1d1d1f] transition-colors mt-4 md:mt-0">
            View Source Code
          </a>
        </footer>
      </main>
    </div>
  )
}
