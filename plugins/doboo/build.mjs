import { build } from 'esbuild';
import { mkdir, readFile } from 'node:fs/promises';
await mkdir('dist', { recursive: true });
const ui=await build({entryPoints:['src/gallery-ui.ts'],bundle:true,minify:true,platform:'browser',format:'esm',target:'es2022',write:false});
const html=(await readFile('src/gallery.html','utf8')).replace('/*DOBOO_SCRIPT*/',()=>ui.outputFiles[0].text.replaceAll('</script','<\\/script'));
await build({ entryPoints: ['src/server.ts','src/catalog-main.ts'], bundle: true, minify: true, platform: 'node', format: 'esm', target: 'node22', outdir: 'dist',outExtension:{'.js':'.mjs'},
  plugins:[{name:'gallery-html',setup(b){b.onLoad({filter:/gallery\.html$/},()=>({contents:`export default ${JSON.stringify(html)}`,loader:'js'}));}}],
  banner: { js: "import { createRequire as __dobooCreateRequire } from 'node:module'; const require = __dobooCreateRequire(import.meta.url);" } });
