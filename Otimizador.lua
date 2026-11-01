--[[
	OTIMIZADOR DE DESEMPENHO (Luau / Roblox)

	COMO USAR
	  1. Crie um LocalScript em StarterPlayer > StarterPlayerScripts e cole tudo.
	  2. Escolha o perfil em PERFIL_INICIAL (logo abaixo).
	  3. No console do CLIENTE dá pra trocar/desfazer em tempo real:
	       shared.Otimizador.Aplicar("Agressivo")
	       shared.Otimizador.Restaurar()
	       print(shared.Otimizador.Status())

	PERFIS
	  Balanceado  sombras e efeitos pesados off; luzes/particulas cortadas por distancia
	  Adaptativo  Balanceado + nivel grafico ajustado sozinho conforme o FPS
	  Agressivo   nivel 3, particulas off, malhas/PBR/audio simplificados
	  Extremo     nivel 1, quase tudo off, materiais lisos (visual bem simplificado)

	COMO FUNCIONA
	  - Roda so no CLIENTE: nao altera o servidor nem os outros jogadores.
	  - Varre Workspace, Lighting e SoundService em fatias de tempo (sem engasgar)
	    e otimiza tambem o que o jogo criar depois (DescendantAdded).
	  - Instancias com a tag "SemOtimizar" (CollectionService) sao ignoradas.
	  - Restaurar() devolve os valores originais (CONFIG.Reversivel = true).

	LIMITES (o Roblox nao permite por script)
	  - Forcar o garbage collector (collectgarbage so aceita "count").
	  - Mudar StreamingEnabled, Lighting.Technology ou FPS maximo em runtime.
	  - ParticleEmitter:Emit() ainda gera particulas mesmo com Enabled = false.
	  - Nao corrige scripts lentos nem excesso de pecas: use o MicroProfiler (Ctrl+F6).
	  - Algumas propriedades podem ser bloqueadas no seu contexto; o script ignora o
	    que falhar (veja Status().falhas e Status().primeiroErro).
]]

if shared.Otimizador then
	warn("[Otimizador] já está em execução; esta cópia foi ignorada.")
	return
end
shared.Otimizador = { Carregando = true }

if game:GetService("RunService"):IsServer() then
	warn("[Otimizador] use este código em um LocalScript (StarterPlayerScripts).")
	shared.Otimizador = nil
	return
end

if not game:IsLoaded() then
	game.Loaded:Wait()
end

----------------------------------------------------------------------
-- SERVIÇOS
----------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local Stats = game:GetService("Stats")

local jogador = Players.LocalPlayer
local RAIZES = { workspace, Lighting, SoundService }

----------------------------------------------------------------------
-- CONFIGURAÇÃO
----------------------------------------------------------------------
local PERFIL_INICIAL = "Extremo" -- "Balanceado" | "Adaptativo" | "Agressivo" | "Extremo"

local CONFIG = {
	MostrarHUD = true,                          -- FPS e estado no topo da tela
	Reversivel = true,                          -- guarda valores originais (permite Restaurar)
	PausarSemFoco = not RunService:IsStudio(),  -- desliga o render 3D com a janela em segundo plano
	FpsAlvo = 60,                               -- use 30 em celulares fracos
	NivelMin = 1,
	NivelMax = 10,                              -- o adaptativo nunca passa do nível do jogador
	OrcamentoMs = 2.5,                          -- ms por quadro gastos varrendo instâncias
	CullPorQuadro = 250,                        -- itens de culling avaliados por quadro
	DistanciaLuzes = 110,                       -- studs (escalada pelo nível gráfico)
	DistanciaEfeitos = 180,
	TagIgnorar = "SemOtimizar",                 -- instâncias com essa tag nunca são tocadas
	Log = true,
}

----------------------------------------------------------------------
-- PERFIS
----------------------------------------------------------------------
type Perfil = {
	qualidade: number?,      -- nível gráfico fixo (1-10); nil = não mexe
	adaptativo: boolean,     -- ajusta o nível gráfico sozinho conforme o FPS
	sombras: boolean,        -- Lighting.GlobalShadows e BasePart.CastShadow
	posFx: string,           -- "nenhum" | "pesados" | "todos"
	luzes: string,           -- "manter" | "culling" | "desligar"
	efeitos: string,         -- "manter" | "culling" | "desligar" (partículas, trails, beams...)
	destaques: boolean,      -- desliga Highlight
	materiais: boolean,      -- material liso e sem reflexo
	malhas: boolean,         -- MeshPart.RenderFidelity = Performance
	pbr: boolean,            -- remove mapas Normal/Metalness/Roughness
	texturas: boolean,       -- Decal/Texture invisíveis
	agua: boolean,           -- terreno: sem ondas, reflexo e grama
	audio: boolean,          -- sem efeitos de áudio (reverb, eco...)
	ocultarNomes: boolean,   -- esconde nome/vida acima dos Humanoids
	distanciaGuis: number?,  -- distância máxima de BillboardGui (studs)
}

local BASE: Perfil = {
	adaptativo = false, sombras = false, posFx = "nenhum", luzes = "manter",
	efeitos = "manter", destaques = false, materiais = false, malhas = false,
	pbr = false, texturas = false, agua = false, audio = false, ocultarNomes = false,
}

local function derivar(base: Perfil, mudancas: { [string]: any }): Perfil
	local novo: any = table.clone(base)
	for chave, valor in mudancas do
		novo[chave] = valor
	end
	return novo
end

local Balanceado = derivar(BASE, {
	sombras = true, posFx = "pesados", luzes = "culling", efeitos = "culling",
	agua = true, distanciaGuis = 250,
})
local Adaptativo = derivar(Balanceado, { adaptativo = true })
local Agressivo = derivar(Balanceado, {
	qualidade = 3, efeitos = "desligar", malhas = true, pbr = true,
	audio = true, distanciaGuis = 150,
})
local Extremo = derivar(Agressivo, {
	qualidade = 1, posFx = "todos", luzes = "desligar", destaques = true,
	materiais = true, texturas = true, ocultarNomes = true, distanciaGuis = 80,
})

local PERFIS: { [string]: Perfil } = {
	Balanceado = Balanceado,
	Adaptativo = Adaptativo,
	Agressivo = Agressivo,
	Extremo = Extremo,
}

----------------------------------------------------------------------
-- ESTADO
----------------------------------------------------------------------
local perfil: Perfil = Balanceado
local nomePerfil = ""
local ativo = false
local restaurando = false
local focado = true

local conexoes: { RBXScriptConnection } = {}
local originais: { [any]: { [string]: any } } = setmetatable({}, { __mode = "k" })

local fila: { any } = {}
local filaIni, filaFim = 1, 0

local cullLista: { any } = {}
local cullCursor = 1
local cullEscala = 1
local cullRegistrados: { [any]: boolean } = setmetatable({}, { __mode = "k" })

local KIND: { [string]: string } = {}
local suporte = { qualidade = true, renderFidelity = true }
local stats = { processados = 0, cortados = 0, falhas = 0 }
local primeiroErro: string? = nil

local nivel = CONFIG.NivelMax
local nivelMax = CONFIG.NivelMax
local nivelOriginal: number? = nil
local amostrasBoas, amostrasRuins = 0, 0
local backoff, bloqueioSubida, ultimaSubida = 30, 0, 0
local inicioT = os.clock()
local acumTempo, acumQuadros = 0, 0
local varreduraAnunciada = false

local hudGui: ScreenGui? = nil
local hud: TextLabel? = nil

local PESADOS = { BloomEffect = true, BlurEffect = true, DepthOfFieldEffect = true, SunRaysEffect = true }
local MAPAS_PBR = { "NormalMap", "MetalnessMap", "RoughnessMap" }

----------------------------------------------------------------------
-- NÚCLEO: alterar propriedade guardando o valor original
----------------------------------------------------------------------
local function set(inst: any, prop: string, valor: any)
	local antigo = inst[prop]
	if antigo == valor then
		return
	end
	if CONFIG.Reversivel then
		local registro = originais[inst]
		if registro == nil then
			registro = {}
			originais[inst] = registro
		end
		if registro[prop] == nil then
			registro[prop] = antigo
		end
	end
	inst[prop] = valor
end

----------------------------------------------------------------------
-- NÍVEL GRÁFICO / MEMÓRIA
----------------------------------------------------------------------
local function lerNivelMotor(): number?
	local ok, valor = pcall(function()
		local r: any = settings().Rendering
		return r.QualityLevel.Value
	end)
	if ok and type(valor) == "number" then
		return valor
	end
	return nil
end

local function escreverNivelMotor(valor: number): boolean
	return (pcall(function()
		local r: any = settings().Rendering
		r.QualityLevel = Enum.QualityLevel:FromValue(valor)
	end))
end

local function aplicarNivel(n: number)
	n = math.clamp(math.floor(n), CONFIG.NivelMin, CONFIG.NivelMax)
	if not escreverNivelMotor(n) then
		suporte.qualidade = false
		if CONFIG.Log then
			warn("[Otimizador] este contexto não permite alterar o nível gráfico; seguindo sem isso.")
		end
		return
	end
	nivel = n
	cullEscala = 0.5 + 0.5 * (n - 1) / 9 -- nível baixo => culling mais curto
end

local function memoriaMb(): number?
	local ok, valor = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	if ok and type(valor) == "number" then
		return valor
	end
	return nil
end

----------------------------------------------------------------------
-- HUD
----------------------------------------------------------------------
local function criarHUD()
	if not CONFIG.MostrarHUD or hudGui then
		return
	end
	local pg = jogador:WaitForChild("PlayerGui")
	if not ativo then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "OtimizadorHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 9999

	local rotulo = Instance.new("TextLabel")
	rotulo.Name = "Info"
	rotulo.AnchorPoint = Vector2.new(0.5, 0)
	rotulo.Position = UDim2.new(0.5, 0, 0, 4)
	rotulo.Size = UDim2.fromOffset(0, 0)
	rotulo.AutomaticSize = Enum.AutomaticSize.XY
	rotulo.BackgroundColor3 = Color3.new(0, 0, 0)
	rotulo.BackgroundTransparency = 0.4
	rotulo.BorderSizePixel = 0
	rotulo.TextColor3 = Color3.new(1, 1, 1)
	rotulo.Font = Enum.Font.Code
	rotulo.TextSize = 13
	rotulo.Text = " Otimizador... "
	rotulo.Parent = gui

	gui.Parent = pg
	hudGui, hud = gui, rotulo
end

local function atualizarHUD(fps: number)
	if hud == nil then
		return
	end
	local gfx
	if not suporte.qualidade then
		gfx = "n/d"
	elseif perfil.adaptativo then
		gfx = tostring(nivel) .. "*" -- * = automático
	elseif perfil.qualidade then
		gfx = tostring(perfil.qualidade)
	else
		gfx = "-"
	end

	local texto = `{nomePerfil}  {math.floor(fps + 0.5)} FPS  GFX {gfx}`
	local mem = memoriaMb()
	if mem then
		texto ..= `  {math.floor(mem)} MB`
	end
	local pendentes = filaFim - filaIni + 1
	if pendentes > 0 then
		texto ..= `  varrendo {pendentes}`
	end
	if stats.cortados > 0 then
		texto ..= `  cull {stats.cortados}`
	end
	hud.Text = " " .. texto .. " "
end

----------------------------------------------------------------------
-- CLASSIFICAÇÃO (cache por ClassName: IsA só roda uma vez por classe)
----------------------------------------------------------------------
local function classificar(inst: Instance): string
	local classe = inst.ClassName
	local tipo = KIND[classe]
	if tipo then
		return tipo
	end

	if inst:IsA("Terrain") then
		tipo = "ignorar" -- Terrain herda de BasePart, mas não pode ser tratado como peça
	elseif inst:IsA("BasePart") then
		tipo = "peca"
	elseif inst:IsA("Light") then
		tipo = "luz"
	elseif inst:IsA("ParticleEmitter") or inst:IsA("Fire") or inst:IsA("Smoke")
		or inst:IsA("Sparkles") or inst:IsA("Beam") or inst:IsA("Trail") then
		tipo = "efeito"
	elseif inst:IsA("Highlight") then
		tipo = "destaque"
	elseif inst:IsA("PostEffect") then
		tipo = "posfx"
	elseif inst:IsA("Atmosphere") then
		tipo = "atmosfera"
	elseif inst:IsA("Clouds") then
		tipo = "nuvens"
	elseif inst:IsA("SoundEffect") then
		tipo = "somfx"
	elseif inst:IsA("Decal") then
		tipo = "decalque" -- inclui Texture
	elseif inst:IsA("SurfaceAppearance") then
		tipo = "pbr"
	elseif inst:IsA("BillboardGui") then
		tipo = "billboard"
	elseif inst:IsA("Humanoid") then
		tipo = "humanoide"
	else
		tipo = "ignorar"
	end

	KIND[classe] = tipo
	return tipo
end

----------------------------------------------------------------------
-- CULLING POR DISTÂNCIA (luzes e efeitos)
----------------------------------------------------------------------
local function registrarCull(inst: any, distancia: number)
	if cullRegistrados[inst] then
		return
	end
	local pai: any = inst.Parent
	local anexo = false
	if pai:IsA("Attachment") then
		anexo = true
	elseif not pai:IsA("BasePart") then
		return
	end
	cullRegistrados[inst] = true
	table.insert(cullLista, {
		inst = inst,
		ancora = pai,
		anexo = anexo,
		dist = distancia,
		cortado = false,
	})
end

local function atualizarCull()
	if #cullLista == 0 then
		return
	end
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local origem = camera.CFrame.Position

	local avaliados = 0
	while avaliados < CONFIG.CullPorQuadro do
		local total = #cullLista
		if total == 0 then
			break
		end
		if cullCursor > total then
			cullCursor = 1
		end

		local item = cullLista[cullCursor]
		local inst = item.inst
		if inst.Parent ~= item.ancora then
			-- destruída ou movida: sai da lista (swap-remove)
			if item.cortado then
				stats.cortados -= 1
			end
			cullRegistrados[inst] = nil
			cullLista[cullCursor] = cullLista[total]
			cullLista[total] = nil
		else
			local posicao = if item.anexo then item.ancora.WorldPosition else item.ancora.Position
			local delta = posicao - origem
			local d2 = delta:Dot(delta)
			local longe = item.dist * cullEscala

			if item.cortado then
				if d2 < longe * longe * 0.72 then -- histerese: volta em ~85% da distância
					item.cortado = false
					stats.cortados -= 1
					if not inst.Enabled then
						inst.Enabled = true
					end
				end
			elseif d2 > longe * longe and inst.Enabled then
				item.cortado = true
				stats.cortados += 1
				inst.Enabled = false
			end
			cullCursor += 1
		end
		avaliados += 1
	end
end

----------------------------------------------------------------------
-- OTIMIZAÇÃO POR INSTÂNCIA
----------------------------------------------------------------------
local function processar(inst: any)
	if inst.Parent == nil then
		return
	end
	local tipo = classificar(inst)
	if tipo == "ignorar" or CollectionService:HasTag(inst, CONFIG.TagIgnorar) then
		return
	end
	stats.processados += 1
	local p = perfil

	if tipo == "peca" then
		if p.sombras then
			set(inst, "CastShadow", false)
		end
		if p.materiais then
			local material = inst.Material
			if material ~= Enum.Material.Neon and material ~= Enum.Material.ForceField then
				set(inst, "Material", Enum.Material.SmoothPlastic)
			end
			set(inst, "Reflectance", 0)
		end
		if p.malhas and suporte.renderFidelity and inst.ClassName == "MeshPart" then
			if not pcall(set, inst, "RenderFidelity", Enum.RenderFidelity.Performance) then
				suporte.renderFidelity = false
			end
		end

	elseif tipo == "luz" then
		if p.luzes == "desligar" then
			set(inst, "Enabled", false)
		elseif p.luzes == "culling" then
			if p.sombras then
				set(inst, "Shadows", false)
			end
			registrarCull(inst, CONFIG.DistanciaLuzes)
		end

	elseif tipo == "efeito" then
		if p.efeitos == "desligar" then
			set(inst, "Enabled", false)
			if inst.ClassName == "ParticleEmitter" then
				set(inst, "Rate", 0)
			end
		elseif p.efeitos == "culling" then
			registrarCull(inst, CONFIG.DistanciaEfeitos)
		end

	elseif tipo == "destaque" then
		if p.destaques then
			set(inst, "Enabled", false)
		end

	elseif tipo == "posfx" then
		if p.posFx == "todos" or (p.posFx == "pesados" and PESADOS[inst.ClassName]) then
			set(inst, "Enabled", false)
		end

	elseif tipo == "atmosfera" then
		if p.posFx == "todos" then
			set(inst, "Density", 0)
			set(inst, "Haze", 0)
			set(inst, "Glare", 0)
		end

	elseif tipo == "nuvens" then
		if p.posFx == "todos" then
			set(inst, "Enabled", false)
		end

	elseif tipo == "somfx" then
		if p.audio then
			set(inst, "Enabled", false)
		end

	elseif tipo == "decalque" then
		if p.texturas then
			set(inst, "Transparency", 1)
		end

	elseif tipo == "pbr" then
		if p.pbr then
			for _, mapa in MAPAS_PBR do
				pcall(set, inst, mapa, "")
			end
		end

	elseif tipo == "billboard" then
		local limite = p.distanciaGuis
		if limite and inst.MaxDistance > limite then
			set(inst, "MaxDistance", limite)
		end

	elseif tipo == "humanoide" then
		if p.ocultarNomes then
			set(inst, "DisplayDistanceType", Enum.HumanoidDisplayDistanceType.None)
			set(inst, "HealthDisplayType", Enum.HumanoidHealthDisplayType.AlwaysOff)
		end
	end
end

----------------------------------------------------------------------
-- FILA EM FATIAS DE TEMPO
----------------------------------------------------------------------
local function enfileirar(inst: Instance)
	filaFim += 1
	fila[filaFim] = inst
end

local function drenarFila()
	if filaIni > filaFim then
		return
	end
	-- sem foco não há render: dá pra gastar mais tempo varrendo
	local orcamento = (if focado then 1 else 4) * CONFIG.OrcamentoMs / 1000
	local limite = os.clock() + orcamento
	local feitos = 0

	while filaIni <= filaFim do
		local inst = fila[filaIni]
		fila[filaIni] = nil
		filaIni += 1

		local ok, erro = pcall(processar, inst)
		if not ok then
			stats.falhas += 1
			if primeiroErro == nil then
				primeiroErro = tostring(erro)
				if CONFIG.Log then
					warn("[Otimizador] primeira falha em " .. tostring(inst) .. ": " .. primeiroErro)
				end
			end
		end

		feitos += 1
		if feitos % 64 == 0 and os.clock() >= limite then
			break
		end
	end

	if filaIni > filaFim then
		fila = {}
		filaIni, filaFim = 1, 0
		if not varreduraAnunciada then
			varreduraAnunciada = true
			if CONFIG.Log then
				print(`[Otimizador] varredura concluída: {stats.processados} instâncias, {stats.falhas} falhas, {#cullLista} em culling.`)
			end
		end
	end
end

----------------------------------------------------------------------
-- QUALIDADE ADAPTATIVA (com histerese e backoff)
----------------------------------------------------------------------
local function aoAmostrar(fps: number)
	atualizarHUD(fps)
	if not perfil.adaptativo or not suporte.qualidade or not focado then
		return
	end
	local agora = os.clock()
	if filaIni <= filaFim or agora - inicioT < 8 then
		return -- ainda varrendo/aquecendo: o FPS não é representativo
	end

	local alvo = CONFIG.FpsAlvo
	if fps < alvo * 0.85 then
		amostrasBoas = 0
		amostrasRuins += 1
		if amostrasRuins >= 3 and nivel > CONFIG.NivelMin then
			amostrasRuins = 0
			if agora - ultimaSubida < 20 then
				backoff = math.min(backoff * 2, 480) -- subir deu ruim: espera mais da próxima
			end
			bloqueioSubida = agora + backoff
			aplicarNivel(nivel - (if fps < alvo * 0.5 then 2 else 1))
		end
	elseif fps >= alvo * 0.97 then
		amostrasRuins = 0
		amostrasBoas += 1
		if amostrasBoas >= 12 and nivel < nivelMax and agora >= bloqueioSubida then
			amostrasBoas = 0
			ultimaSubida = agora
			aplicarNivel(nivel + 1)
		elseif amostrasBoas >= 60 then
			backoff = 30 -- estável há muito tempo: esquece o histórico
		end
	else
		amostrasRuins = 0
	end
end

local function aoQuadro(dt: number)
	acumTempo += dt
	acumQuadros += 1
	if acumTempo >= 1 then
		local fps = acumQuadros / acumTempo
		acumTempo, acumQuadros = 0, 0
		aoAmostrar(fps)
	end
	drenarFila()
	if focado then
		atualizarCull()
	end
end

----------------------------------------------------------------------
-- AJUSTES GLOBAIS (aplicados uma vez)
----------------------------------------------------------------------
local function aplicarGlobais()
	if perfil.sombras then
		pcall(set, Lighting, "GlobalShadows", false)
	end

	if perfil.agua then
		local terreno = workspace.Terrain
		pcall(set, terreno, "WaterWaveSize", 0)
		pcall(set, terreno, "WaterWaveSpeed", 0)
		pcall(set, terreno, "WaterReflectance", 0)
		pcall(set, terreno, "Decoration", false) -- grama; pode ser bloqueado
	end

	if perfil.audio then
		pcall(set, SoundService, "AmbientReverb", Enum.ReverbType.NoReverb)
	end

	if perfil.adaptativo then
		-- nunca sobe além do nível que o próprio jogador escolheu
		nivelMax = if nivelOriginal and nivelOriginal >= 1
			then math.min(CONFIG.NivelMax, math.floor(nivelOriginal))
			else CONFIG.NivelMax
		nivel = nivelMax
		cullEscala = 1
	elseif perfil.qualidade then
		aplicarNivel(perfil.qualidade)
	end
end

----------------------------------------------------------------------
-- CICLO DE VIDA
----------------------------------------------------------------------
local function iniciar(nome: string)
	local escolhido = PERFIS[nome]
	if not escolhido then
		warn(`[Otimizador] perfil desconhecido: {nome}`)
		return
	end

	perfil, nomePerfil, ativo = escolhido, nome, true
	stats.processados, stats.cortados, stats.falhas = 0, 0, 0
	primeiroErro = nil
	varreduraAnunciada = false
	fila, filaIni, filaFim = {}, 1, 0
	cullCursor, cullEscala = 1, 1
	amostrasBoas, amostrasRuins = 0, 0
	backoff, bloqueioSubida, ultimaSubida = 30, 0, 0
	acumTempo, acumQuadros = 0, 0
	inicioT = os.clock()

	nivelOriginal = lerNivelMotor()
	aplicarGlobais()

	-- 1) acompanha o que o jogo criar daqui pra frente
	for _, raiz in RAIZES do
		table.insert(conexoes, raiz.DescendantAdded:Connect(enfileirar))
	end

	-- 2) enfileira tudo que já existe (processado em fatias, sem travar)
	for _, raiz in RAIZES do
		for _, descendente in raiz:GetDescendants() do
			filaFim += 1
			fila[filaFim] = descendente
		end
	end

	table.insert(conexoes, RunService.Heartbeat:Connect(aoQuadro))

	-- foco da janela (sempre monitora; só pausa o 3D se PausarSemFoco)
	table.insert(conexoes, UserInputService.WindowFocusReleased:Connect(function()
		focado = false
		if CONFIG.PausarSemFoco and not UserInputService.VREnabled then
			pcall(function()
				RunService:Set3dRenderingEnabled(false)
			end)
		end
	end))
	table.insert(conexoes, UserInputService.WindowFocused:Connect(function()
		focado = true
		if CONFIG.PausarSemFoco and not UserInputService.VREnabled then
			pcall(function()
				RunService:Set3dRenderingEnabled(true)
			end)
		end
	end))

	task.spawn(criarHUD)

	if CONFIG.Log then
		print(`[Otimizador] perfil "{nome}" ativo; varrendo {filaFim} instâncias em fatias de {CONFIG.OrcamentoMs} ms/quadro.`)
	end
end

local function restaurar()
	if not ativo or restaurando then
		return
	end
	restaurando = true
	ativo = false

	for _, conexao in conexoes do
		conexao:Disconnect()
	end
	table.clear(conexoes)

	-- religa o que o culling tinha desligado
	for _, item in cullLista do
		if item.cortado then
			pcall(function()
				item.inst.Enabled = true
			end)
		end
	end
	table.clear(cullLista)
	table.clear(cullRegistrados)
	cullCursor, stats.cortados = 1, 0
	fila, filaIni, filaFim = {}, 1, 0

	pcall(function()
		RunService:Set3dRenderingEnabled(true)
	end)
	if hudGui then
		hudGui:Destroy()
		hudGui, hud = nil, nil
	end
	if nivelOriginal then
		escreverNivelMotor(nivelOriginal)
	end

	if CONFIG.Reversivel then
		local feitos = 0
		for inst, props in originais do
			for prop, valor in props do
				pcall(function()
					inst[prop] = valor
				end)
			end
			feitos += 1
			if feitos % 1500 == 0 then
				task.wait() -- devolve em fatias para não engasgar
			end
		end
		table.clear(originais)
	else
		warn("[Otimizador] Reversivel = false: otimizador parado, mas os valores originais não foram guardados.")
	end

	restaurando = false
	if CONFIG.Log then
		print("[Otimizador] restaurado.")
	end
end

local function aplicar(nome: string)
	if not PERFIS[nome] then
		warn(`[Otimizador] perfil inválido "{nome}". Use: Balanceado, Adaptativo, Agressivo ou Extremo.`)
		return
	end
	if ativo then
		restaurar()
	end
	while restaurando do
		task.wait()
	end
	iniciar(nome)
end

local function status()
	return {
		perfil = nomePerfil,
		ativo = ativo,
		nivelGrafico = nivel,
		processados = stats.processados,
		pendentes = math.max(0, filaFim - filaIni + 1),
		emCulling = #cullLista,
		cortadosAgora = stats.cortados,
		falhas = stats.falhas,
		primeiroErro = primeiroErro,
	}
end

----------------------------------------------------------------------
-- API PÚBLICA + INÍCIO
----------------------------------------------------------------------
shared.Otimizador = {
	Perfis = { "Balanceado", "Adaptativo", "Agressivo", "Extremo" },
	Aplicar = aplicar,
	Restaurar = function()
		task.spawn(restaurar)
	end,
	Status = status,
}

if not PERFIS[PERFIL_INICIAL] then
	warn(`[Otimizador] PERFIL_INICIAL "{PERFIL_INICIAL}" não existe; usando "Agressivo".`)
	PERFIL_INICIAL = "Agressivo"
end
iniciar(PERFIL_INICIAL)

--[[
	DICAS PARA FAZER NO STUDIO (nenhum script de cliente consegue fazer isso):
	  1. Workspace.StreamingEnabled = true, com raios (Min/Target) moderados.
	  2. Lighting.Technology: Compatibility ou ShadowMap se você não precisa de Future.
	  3. Peças estáticas sempre Anchored; prefira MeshParts a milhares de Parts soltas.
	  4. Evite loops "while true do wait() end"; prefira eventos e task.defer/task.delay.
	  5. Meça antes de otimizar: MicroProfiler (Ctrl+F6) e Developer Console (F9).
]]
