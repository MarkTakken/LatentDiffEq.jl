# GOKU-NET MODEL
#
# Based on
# https://github.com/FluxML/model-zoo/blob/master/vision/vae_mnist/vae_mnist.jl
# https://arxiv.org/abs/1806.07366
# https://arxiv.org/abs/2003.10775

################################################################################
## Encoder definition

struct GOKU_encoder <: AbstractEncoder

    linear
    rnn
    rnn_μ
    rnn_logσ²
    lstm_forward        # TODO: Implement bidirectional LSTM : https://github.com/maetshju/flux-blstm-implementation/blob/master/01-blstm.jl
    lstm_backward
    lstm_μ                                           # https://github.com/AzamatB/Tacotron2.jl
    lstm_logσ²

    device

    function GOKU_encoder(input_dim, hidden_dim1, hidden_dim2, hidden_dim3, rnn_input_dim, rnn_output_dim, latent_dim, device)

        l1 = Dense(input_dim, hidden_dim1, relu)
        l2 = Dense(hidden_dim1, hidden_dim1, relu)
        l3 = Dense(hidden_dim1, hidden_dim1, relu)
        l4 = Dense(hidden_dim1, rnn_input_dim, relu)

        linear = Chain(l1,
                        SkipConnection(l2, +),
                        SkipConnection(l3, +),
                        l4) |> device

        rnn = Chain(RNN(rnn_input_dim, rnn_output_dim, relu),
                    RNN(rnn_output_dim, rnn_output_dim, relu)) |> device

        # rnn = Chain(LSTM(rnn_input_dim, rnn_output_dim),
        #             LSTM(rnn_output_dim, rnn_output_dim)) |> device


        rnn_μ = Dense(rnn_output_dim, latent_dim) |> device
        rnn_logσ² = Dense(rnn_output_dim, latent_dim) |> device

        lstm_forward = Chain(LSTM(rnn_input_dim, rnn_output_dim),
                                LSTM(rnn_output_dim, rnn_output_dim)) |> device

        lstm_backward = Chain(LSTM(rnn_input_dim, rnn_output_dim),
                                LSTM(rnn_output_dim, rnn_output_dim)) |> device


        lstm_μ = Dense(rnn_output_dim*2, latent_dim) |> device
        lstm_logσ² = Dense(rnn_output_dim*2, latent_dim) |> device

        new(linear, rnn, rnn_μ, rnn_logσ², lstm_forward, lstm_backward, lstm_μ, lstm_logσ², device)
    end
end


function (encoder::GOKU_encoder)(x)

    # Pass all states in the time series in dense layer
    h = encoder.linear.(x)
    h_rev = reverse(h)

    # Pass an RNN and an LSTM through latent states
    rnn_out = encoder.rnn.(h_rev)[end]
    lstm_out_f = encoder.lstm_forward.(h)[end]
    lstm_out_b = encoder.lstm_backward.(h_rev)[end]
    bi_lstm_out = vcat(lstm_out_f, lstm_out_b)

    reset!(encoder.rnn)
    reset!(encoder.lstm_forward)
    reset!(encoder.lstm_backward)

    # Return RNN/LSTM ouput passed trough dense layers (RNN -> z₀, LSTM -> p)
    encoder.rnn_μ(rnn_out), encoder.rnn_logσ²(rnn_out), encoder.lstm_μ(bi_lstm_out), encoder.lstm_logσ²(bi_lstm_out)
end

################################################################################
## Decoder definition

struct GOKU_decoder <: AbstractDecoder

    solver
    ode_prob
    transform

    z₀_linear
    p_linear
    gen_linear

    SDE::Bool

    device

    function GOKU_decoder(input_dim, hidden_dim1, hidden_dim2, hidden_dim3,
                            latent_dim, hidden_dim_latent_ode, ode_dim, p_dim,
                            ode_prob, transform, solver, SDE, device)

        z₀_linear = Chain(Dense(latent_dim, hidden_dim_latent_ode, relu),
                          Dense(hidden_dim_latent_ode, ode_dim)) |> device
        p_linear = Chain(Dense(latent_dim, hidden_dim_latent_ode, relu),
                         Dense(hidden_dim_latent_ode, p_dim, softplus)) |> device


        l1 = Dense(ode_dim, hidden_dim1, relu)
        l2 = Dense(hidden_dim1, hidden_dim1, relu)
        l3 = Dense(hidden_dim1, hidden_dim1, relu)
        # l4 = Dense(hidden_dim1, input_dim, σ)
        l4 = Dense(hidden_dim1, input_dim, tanh)

        gen_linear = Chain(l1,
                        SkipConnection(l2, +),
                        SkipConnection(l3, +),
                        l4)  |> device

        # _ode_prob = ODEProblem(ode_func, zeros(Float32, ode_dim), (0.f0, 1.f0), zeros(Float32, p_dim))
        # ode_prob,_ = auto_optimize(_ode_prob, verbose = false, static = false);

        new(solver, ode_prob, transform, z₀_linear, p_linear, gen_linear, SDE, device)

    end

end


function (decoder::GOKU_decoder)(latent_z₀, latent_p, t)

    ## Pass sampled latent states in dense layers
    z₀ = decoder.z₀_linear(latent_z₀)
    p = decoder.p_linear(latent_p)

    #####
    # Function definition for ensemble problem
    prob_func = (prob,i,repeat) -> remake(prob, u0=z₀[:,i], p = p[:,i]) # TODO: try using views and switching indexes to see if the performance improves
    function output_func(sol, i)
        # Check if solve was successful, if not fill z_pred with zeros to avoid problems with dimensions matches
        if sol.retcode != :Success
            return (zeros(Float32, size(z₀, 1), size(t,1)), false)
            # return (1000*ones(Float32, size(z₀, 1), size(t,1)), false)
        else
            return (Array(sol), false)
        end
    end
    #####

    ## Adapt problem to given time span and create ensemble problem definition
    prob = remake(decoder.ode_prob; tspan = (t[1],t[end]))
    ens_prob = EnsembleProblem(prob, prob_func = prob_func, output_func = output_func)

    ## Solve
    if decoder.SDE
        pred_z = solve(ens_prob, SOSRI(), sensealg=ForwardDiffSensitivity(), trajectories=size(p, 2), saveat = t) |> decoder.device
    else
        pred_z = solve(ens_prob, decoder.solver,  EnsembleThreads(), trajectories=size(p, 2), saveat = t) |> decoder.device
    end
    
    # Transform the resulting output (Mainly used for Kuramoto system to pass from phase -> time space)
    pred_z = decoder.transform(pred_z)

    ## Create output data shape
    pred_z = decoder.gen_linear.(Flux.unstack(pred_z, 2)) # TODO : create new dataset from a trained generation function

    return pred_z, z₀, p

end

################################################################################
## Goku definition (Encoder/decoder container)

struct Goku <: AbstractModel

    encoder::GOKU_encoder
    decoder::GOKU_decoder

    variational::Bool

    device

    function Goku(input_dim, hidden_dim1, hidden_dim2, hidden_dim3, rnn_input_dim, rnn_output_dim, latent_dim, hidden_dim_latent_ode, ode_dim, p_dim, ode_prob, transform, solver, variational, SDE, device)

        encoder = GOKU_encoder(input_dim, hidden_dim1, hidden_dim2, hidden_dim3, rnn_input_dim, rnn_output_dim, latent_dim, device)
        decoder = GOKU_decoder(input_dim, hidden_dim1, hidden_dim2, hidden_dim3, latent_dim, hidden_dim_latent_ode, ode_dim, p_dim, ode_prob, transform, solver, SDE, device)

        new(encoder, decoder, variational, device)

    end

end


function (goku::Goku)(x, t)
    ## Get encoded latent initial states and parameters
    latent_z₀_μ, latent_z₀_logσ², latent_p_μ, latent_p_logσ² = goku.encoder(x)

    ## Sample from the distributions
    if goku.variational
        latent_z₀ = latent_z₀_μ + goku.device(randn(Float32, size(latent_z₀_logσ²))) .* exp.(latent_z₀_logσ²/2f0)
        latent_p = latent_p_μ + goku.device(randn(Float32, size(latent_p_logσ²))) .* exp.(latent_p_logσ²/2f0)
    else
        latent_z₀ = latent_z₀_μ
        latent_p = latent_p_μ
    end
    ## Get predicted output
    pred_x, pred_z₀, pred_p = goku.decoder(latent_z₀, latent_p, t)

    return ((latent_z₀_μ, latent_z₀_logσ²), (latent_p_μ, latent_p_logσ²)), pred_x, (pred_z₀, pred_p)

end


# for ILC

function (goku::Goku)(x::Array{T,2}, t) where T
    
    ## Get encoded latent initial states and parameters
    latent_z₀_μ, latent_z₀_logσ², latent_p_μ, latent_p_logσ² = goku.encoder(x)

    ## Sample from the distributions
    if goku.variational
        latent_z₀ = latent_z₀_μ + goku.device(randn(Float32, size(latent_z₀_logσ²))) .* exp.(latent_z₀_logσ²/2f0)
        latent_p = latent_p_μ + goku.device(randn(Float32, size(latent_p_logσ²))) .* exp.(latent_p_logσ²/2f0)
    else
        latent_z₀ = latent_z₀_μ
        latent_p = latent_p_μ
    end

    ## Get predicted output
    pred_x, pred_z₀, pred_p = goku.decoder(latent_z₀, latent_p, t)

    return ((latent_z₀_μ, latent_z₀_logσ²), (latent_p_μ, latent_p_logσ²)), pred_x, (pred_z₀, pred_p)
end

function (encoder::GOKU_encoder)(x::Array{T,2}) where T
    # @show x
    # @show encoder.linear[1].W
    # Pass all states in the time series in dense layer
    h = encoder.linear(x)
    # @show h[1,1:3]
    h_rev = reverse(h, dims=2)
    # @show h_rev[1,end-2:end]

    # Pass an RNN and an LSTM through latent states
    rnn_out = encoder.rnn.(eachcol(h_rev))[end]
    lstm_out = encoder.lstm.(eachcol(h))[end]

    lstm_out_f = encoder.lstm_forward.(eachcol(h))[end]
    lstm_out_b = encoder.lstm_backward.(eachcol(h_rev))[end]
    bi_lstm_out = vcat(lstm_out_f, lstm_out_b)

    reset!(encoder.rnn)
    reset!(encoder.lstm_forward)
    reset!(encoder.lstm_backward)

    # Return RNN/LSTM ouput passed trough dense layers (RNN -> z₀, LSTM -> p)
    encoder.rnn_μ(rnn_out), encoder.rnn_logσ²(rnn_out), encoder.lstm_μ(bi_lstm_out), encoder.lstm_logσ²(bi_lstm_out)
end


function (decoder::GOKU_decoder)(latent_z₀::Array{T,1}, latent_p, t) where T
    ## Pass sampled latent states in dense layers
    z₀ = decoder.z₀_linear(latent_z₀)
    p = decoder.p_linear(latent_p)

    ## Adapt problem to given time span, parameters and initial conditions
    prob = remake(decoder.ode_prob, u0=z₀[:], p = p[:], tspan = (t[1],t[end]))

    ## Solve
    if decoder.SDE
        pred_z = solve(prob, SOSRI(), sensealg=ForwardDiffSensitivity(), saveat = t) |> decoder.device
    else
        pred_z = solve(prob, decoder.solver, saveat = t) |> decoder.device
    end

    # Transform the resulting output (Mainly used for Kuramoto system to pass from phase -> time space)
    pred_z = decoder.transform(pred_z)

    ## Create output data shape
    pred_z = decoder.gen_linear.(Flux.unstack(pred_z, 2)) # TODO : create new dataset from a trained generation function
    
    return pred_z, z₀, p
end


Flux.@functor GOKU_encoder
Flux.@functor GOKU_decoder
Flux.@functor Goku
