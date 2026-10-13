import { build } from 'esbuild';
import { mkdir, readFile } from 'node:fs/promises';
await mkdir('dist', { recursive: true });
const ui=await build({entryPoints:['src/gallery-ui.ts'],bundle:true,minify:true,platform:'browser',format:'esm',target:'es2022',write:false});
// Git may check out the HTML with CRLF on Windows; embed the same bytes on every OS.
const html=(await readFile('src/gallery.html','utf8')).replace(/\r\n?/g,'\n').replace('/*DOBOO_SCRIPT*/',()=>ui.outputFiles[0].text.replaceAll('</script','<\\/script'));
await build({ entryPoints: ['src/server.ts','src/catalog-main.ts'], bundle: true, minify: true, platform: 'node', format: 'esm', target: 'node22', outdir: 'dist',outExtension:{'.js':'.mjs'},
  plugins:[{name:'gallery-html',setup(b){b.onLoad({filter:/gallery\.html$/},()=>({contents:`export default ${JSON.stringify(html)}`,loader:'js'}));}}],
  banner: { js: "import { createRequire as __dobooCreateRequire } from 'node:module'; const require = __dobooCreateRequire(import.meta.url);" } });
